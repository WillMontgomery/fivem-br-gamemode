import { useEffect, useRef, useState } from 'react'
import { useUi } from '../store'
import type { SquadMember, SquadPayload } from '../bridge/types'
import VoiceMark from './VoiceMark'

/**
 * Squad status.
 *
 * Squad membership and each member's state come from the server roster, never
 * from enumerating nearby players -- a squadmate across the map is out of scope
 * and would simply be missing.
 *
 * VOICE IS A MARK BESIDE THE NAME, NOT A LINE AT THE BOTTOM OF THE SCREEN.
 * Owner, 2026-08-22: "how about instead of showing this text, we show something
 * in the top squad panel next to each player which shows if they are muted, not
 * listening, or talking." The model -- what the mark is allowed to claim about
 * whom -- is argued in full in hud/VoiceMark.tsx.
 *
 * IT IS BUILT FROM WHAT THE CLIENT IS TOLD, AND IT IS TOLD EXACTLY THREE
 * THINGS: who is talking, this client's own verdict, and -- since 2026-08-29 --
 * one boolean per squadmate saying their voice carries nothing. The third is
 * the owner's, from a playtest: "the squad panel works, but doesn't accurately
 * show when others in the squad have 'off' selected." Nothing wider than that
 * bit is published, and tools/check_squad_voice.lua fails the build if it ever
 * is.
 *
 * A MATE DYING IS A SEQUENCE, NOT AN OPACITY CHANGE. Fading a row out is the
 * least legible thing a HUD can do: it reads as a render glitch rather than as
 * something happening. It now flashes, the bars DRAIN (slower than a damage
 * move, so it reads as dying rather than as a large hit), then OUT stamps in.
 *
 * DOWNED AND DEAD MUST NEVER LOOK ALIKE. Downed pulses the colour tag and turns
 * the health bar red -- it is recoverable and the player has a decision to
 * make. Dead is finished and still.
 *
 * ...AND SINCE THE REVIVE KEY, "DEAD" IS TWO THINGS. A mate whose key the squad
 * holds is out of the match and coming back, and the panel drew him identically
 * to one nobody can reach: "I also saw nothing in the squad panel indicating
 * that a revive key had been retrieved" (owner, 2026-08-30). The row now carries
 * a key mark and stops being faded all the way down. See KeyMark.
 *
 * ...AND A DECISION NEEDS A NUMBER. Two of the three things the owner could not
 * read off this panel in the playtest were quantities: how long a downed mate
 * has left, and what a mate's health and shield actually are. Both are now
 * numerals rather than lengths -- see RowClock and VitalBar below. A bar
 * answers "roughly how much?" at a glance and that is all it will ever answer;
 * "can I get there in time" and "is he one shot from down" are questions with
 * digits in them.
 *
 * ...AND THE ONE DEADLINE THAT IS A LENGTH AGAIN, WHICH IS NOT A REVERSAL. The
 * key's pickup window drew as `142s` beside the key mark until 2026-09-02, when
 * the owner replaced it with "a red line at the bottom of the player's card".
 * The rule above still holds and this is the case it does not cover: the
 * question a squad asks about a key is "is there still time", not "how many
 * seconds" -- nobody paces a run across the map off a number -- and the digits
 * were the half of it that needed a caption to say what they counted. See
 * KeyDrain.
 */

type Phase = 'alive' | 'down' | 'dying' | 'dead'

function phaseOf(m: SquadMember): Exclude<Phase, 'dying'> {
  if (m.state === 'dead' || m.state === 'left') return 'dead'
  if (m.state === 'dbno') return 'down'
  return 'alive'
}

/**
 * Holds a member in a transient `dying` phase for the length of the drain, so
 * the bars have something to animate to before the row goes flat. Without it
 * the row is already at zero on the frame the state arrives and there is
 * nothing to see.
 */
function useDeathSequence(m: SquadMember) {
  const target = phaseOf(m)
  const [phase, setPhase] = useState<Phase>(target)
  const [flash, setFlash] = useState(0)
  const prev = useRef(target)

  useEffect(() => {
    if (target === prev.current) return
    const from = prev.current
    prev.current = target

    // Any transition INTO a bad state is worth a flash -- taking a knee and
    // being finished are both news.
    if (target !== 'alive') setFlash((f) => f + 1)

    if (target === 'dead' && from !== 'dead') {
      setPhase('dying')
      const t = window.setTimeout(() => setPhase('dead'), 640)
      return () => window.clearTimeout(t)
    }
    setPhase(target)
  }, [target])

  return { phase, flash }
}

/**
 * A DEADLINE ON A SQUAD ROW, COUNTED DOWN.
 *
 * TWO CALLERS, AND THEY ARE ONE COMPONENT ON PURPOSE.
 *
 * HOW LONG A DOWNED MATE HAS LEFT. Owner, from the playtest: "There's no way
 * for team mates to see how much time is left on DBNO players." A squad's whole
 * decision -- push the pickup or take the fight first -- is a question about
 * this number, and the only player who could see it was the one who could do
 * nothing with it.
 *
 * IT COUNTED THE KEY'S PICKUP TOO, FROM 2026-08-31 UNTIL 2026-09-02, and the
 * owner has replaced that half with a shape:
 *
 *   "the timer is not clear either. It should be more obvious what that timer
 *    means."
 *   "what if we put a red line at the bottom of the player's card to represent
 *    the timer? The bar will become less filled (akin to the bleed out timer
 *    card) as the time runs out"
 *
 * So the pickup is `KeyDrain` below and this is a bleed clock again. The `big`
 * and `colour` props it grew to serve two callers are gone with the second
 * caller: a prop nothing passes is a claim about flexibility that no longer has
 * a case behind it, and the comment explaining it would have been the first
 * thing to go stale.
 *
 * ONE FORMAT, INCLUDING PAST A MINUTE. `Math.ceil(left / 1000)` and an `s`,
 * whatever the number -- the bleed runs from 120s (BR.Config.Match.dbnoBleedBase)
 * so three-digit seconds are normal here.
 *
 * THE SAME NUMBER THE DOWNED PLAYER IS WATCHING, by construction: same field,
 * same clock, same `Math.ceil(left / 1000)` and the same trailing `s` as
 * DbnoOverlay. Two countdowns for one deadline that round differently would
 * have a squad and their downed mate reading two different answers out loud.
 *
 * `endsAt` is a SERVER timestamp -- both of them are, off the same squad beacon
 * -- so it is compared to `Date.now() + clockOffset`, the rule StormBar,
 * WarmupTimer and DbnoOverlay already follow. Against a bare Date.now() it is wrong by however far the two
 * clocks happen to sit apart, which is a number nobody can predict and
 * everybody would report as a broken timer.
 *
 * WRITTEN STRAIGHT TO THE NODE, exactly as DbnoOverlay does it, because the
 * alternative is re-rendering a plate several times a second to move two
 * digits -- and a squad can now hold three of these at once per deadline.
 *
 * ON AN INTERVAL RATHER THAN rAF, which is the one place this deliberately
 * differs from DbnoOverlay. That component is on rAF because it also drives a
 * bar's transform, which genuinely wants a value every frame. There is no bar
 * here: the only output is a whole number of seconds, so 60 callbacks a second
 * per downed mate would be ~180 wakeups to change one character. 250ms is fast
 * enough that the digit never visibly lags the player's own placard, and the
 * text is only written when it actually differs, so a tick that changes nothing
 * touches no DOM at all.
 */
function RowClock({ endsAt }: { endsAt: number }) {
  const ref = useRef<HTMLSpanElement>(null)
  const offset = useUi((s) => s.clockOffset)

  useEffect(() => {
    const tick = () => {
      const left = Math.max(0, endsAt - (Date.now() + offset))
      const txt = `${Math.ceil(left / 1000)}s`
      if (ref.current && ref.current.textContent !== txt) {
        ref.current.textContent = txt
      }
    }
    tick()
    const id = window.setInterval(tick, 250)
    return () => window.clearInterval(id)
  }, [endsAt, offset])

  return (
    <span
      ref={ref}
      // The bars' slot, where this is the row's only number and should read as
      // such. 1.05rem was `big`, and it is the only size this ever draws at now
      // -- see the header for the caller that went away.
      className="font-display leading-none tabular-nums shrink-0 text-[1.05rem]"
      style={{ color: 'var(--color-danger)', textShadow: 'var(--shadow-text)' }}
    >
      --
    </span>
  )
}

/**
 * HOW MUCH OF THE PICKUP WINDOW IS LEFT, AS A LINE ALONG THE CARD'S FOOT.
 *
 * ═══ THE OWNER'S DESIGN, 2026-09-02, IN HIS WORDS ═══
 *
 *   "what if we put a red line at the bottom of the player's card to represent
 *    the timer? The bar will become less filled (akin to the bleed out timer
 *    card) as the time runs out"
 *
 * It replaces a `142s` that sat in the corner beside the key mark, which he had
 * just reported: "the timer is not clear either. It should be more obvious what
 * that timer means." A number needs a label to say what it counts; a bar
 * emptying along the bottom of one mate's card is already the sentence.
 *
 * ═══ IT IS THE BLEED CARD'S BAR, NOT A SECOND ONE ═══
 *
 * "(akin to the bleed out timer card)" names the reference, so this is that
 * markup: the same `bg-black/60` track, the same `.bar-fill` child scaled with
 * `transform: scaleX()`, the same `h-[0.2rem]`, and the same
 * `var(--color-danger)`. See DbnoOverlay's bar -- and its note on why the total
 * is HELD IN A REF rather than recomputed, which this inherits along with
 * everything else.
 *
 * ⚠ THE COLOUR IS THE TOKEN AND NOT A RED. `--color-danger` is one of the four
 * this interface remaps for colourblind modes -- index.css, and DbnoOverlay's
 * own note where it reaches for `--color-hp` "rather than a literal green". A
 * hex here would be a bar that stops matching the card it was asked to look
 * like the day somebody changes the setting.
 *
 * ═══ ON AN INTERVAL, WHICH IS WHERE IT PARTS FROM THAT CARD ═══
 *
 * DbnoOverlay drives its bar on rAF because a bleed is 120 seconds across a
 * 14rem placard. This is 180 seconds across a 13rem card that is one of up to
 * four: the fill moves about a pixel a second, and three rAF loops to do that
 * would be ~180 wakeups a second for sub-pixel motion. `.bar-fill` already
 * carries a 300ms linear transition built to blend 250ms-stepped writes into
 * continuous motion (see index.css), so a 250ms interval through it looks
 * identical and is this panel's existing clock discipline -- RowClock above
 * makes the same trade for the same reason.
 *
 * THE DENOMINATOR IS THE FIRST READING, RE-SEEDED WHEN THE DEADLINE CHANGES.
 * The panel is told when the pickup ends and never how long it was, so the bar
 * is "of what is left from when I first saw it" -- full on the frame a mate goes
 * out, which is when everybody is looking at it. A `totalRef` reset keyed to
 * `endsAt` is what makes the next key start full instead of inheriting the last
 * one's scale.
 */
function KeyDrain({ endsAt }: { endsAt: number }) {
  const ref = useRef<HTMLDivElement>(null)
  const offset = useUi((s) => s.clockOffset)
  const totalRef = useRef(0)

  useEffect(() => {
    totalRef.current = 0
    const tick = () => {
      const left = Math.max(0, endsAt - (Date.now() + offset))
      if (totalRef.current <= 0) totalRef.current = Math.max(1, left)
      if (ref.current) {
        ref.current.style.transform =
          `scaleX(${Math.min(1, left / totalRef.current)})`
      }
    }
    tick()
    const id = window.setInterval(tick, 250)
    return () => window.clearInterval(id)
  }, [endsAt, offset])

  return (
    // ALONG THE FOOT OF THE PLATE, which is `position: relative` already (see
    // index.css `.plate`) and clips its own bottom-left chamfer -- so the line
    // ends where the card's corner is cut rather than overhanging it.
    //
    // `pointer-events-none` because the plate is a readout: nothing in this
    // panel is clickable and a strip that could swallow a hover is a bug
    // waiting for the day something is.
    <div className="absolute inset-x-0 bottom-0 h-[0.2rem] overflow-hidden bg-black/60 pointer-events-none">
      <div
        ref={ref}
        className="bar-fill h-full"
        style={{ width: '100%', background: 'var(--color-danger)' }}
      />
    </div>
  )
}

/**
 * ONE BAR AND ITS NUMBER, side by side.
 *
 * Owner, from the playtest: "There's no way to see a squad member's health or
 * shield level value in numbers. Don't put the numbers inside the bars like the
 * player's own health - those numbers would be too small to read."
 *
 * SO THE NUMBER IS OUTSIDE THE BAR, and that is the whole instruction. Vitals
 * grew its bar to 1.05rem so a 0.88rem numeral could live inside it; these bars
 * are 0.4rem, a quarter of that, and there is no version of a numeral inside
 * one that a player reads mid-fight. Beside it, the number is free to be
 * BIGGER than anything else in the row -- 0.82rem against the name's 0.72rem --
 * because nothing has to grow to hold it.
 *
 * BESIDE RATHER THAN UNDER, because a squad panel is a stack of pairs: hp over
 * shield, four times. A number under its bar sits closer to the NEXT bar than
 * to its own, and the reader has to work out which line owns which figure.
 * Beside, on one baseline, the pairing is not a question -- and the two
 * numbers form a right-hand column that reads down as fast as the bars do.
 *
 * FIXED-WIDTH AND RIGHT-ALIGNED, in tabular figures, so 7 and 100 put their
 * last digit in the same place and the bars either side of them never move.
 *
 * The numeral wears its bar's colour, which is the same argument the row's
 * edge tag makes: the colour is on the thing rather than beside it. It comes
 * from --color-hp / --color-shield / --color-danger rather than a literal, so
 * it follows the colourblind modes exactly as the fill it names does.
 */
function VitalBar({ value, colour, dying }:
  { value: number; colour: string; dying: boolean }) {
  const pct = Math.max(0, Math.min(1, value / 100))
  return (
    <div className="flex items-center gap-1">
      {/* 0.4rem, and it has been raised twice. These began as 1px hairlines,
          went to 0.2rem, and were STILL too thin to read at a glance (user,
          2026-08-08 -- "this was true before we started"). A squadmate's
          health is something you check in the middle of a fight, with your
          eyes mostly elsewhere; a line you have to look at twice is a line
          you stop looking at. At 0.4rem the fill has enough body to carry its
          colour, which is what actually does the reading -- green, red, or
          nearly gone. */}
      <div className="flex-1 h-[0.4rem] rounded-full bg-black/55 overflow-hidden">
        <div
          className={`bar-fill h-full rounded-full${dying ? ' mate-drain' : ''}`}
          style={{
            width: '100%',
            transform: `scaleX(${pct})`,
            background: colour,
          }}
        />
      </div>
      <span
        className="font-display leading-none tabular-nums text-[0.82rem]
                   w-[1.65rem] text-right shrink-0"
        style={{ color: colour, textShadow: 'var(--shadow-text)' }}
      >
        {Math.round(value)}
      </span>
    </div>
  )
}

/**
 * WHAT LEVEL THIS MATE IS.
 *
 * Owner, 2026-08-22: "We need some way in the squad panel to see the levels of
 * our teammates near their name." That is the whole specification, and the
 * whole of what is drawn: a number, beside the name, with no word attached.
 *
 * NO CAPTION, DELIBERATELY. "Lv" or "Level" is interface text nobody asked for,
 * in the tightest row on the HUD -- the panel is 13rem wide and this row
 * already holds a voice mark, a name that truncates, and a DOWN/OUT stamp. A
 * bare figure beside a player's name is the convention every battle royale
 * shares, and the panel's other numbers are already caption-free.
 *
 * WHICH LEAVES IT TO THE STYLING TO SAY THIS IS NOT A VITAL, because the row's
 * other numerals are hp and shield and they are large, colour-coded and
 * urgent. This one is 0.62rem in --color-text-dim: the stamp's size and the
 * caption shade, so it sits in the name's group as an attribute OF the name
 * rather than as a third quantity in the row.
 *
 * AFTER THE NAME RATHER THAN BEFORE IT, and that is a layout requirement, not
 * a preference. VoiceMark's slot exists to pin the name's left edge for the
 * life of the panel; a variable-width number between the mark and the name
 * would unpin it again and shift the name sideways the moment anyone crossed
 * from 9 to 10. Placed after, the name's left edge never moves, and the level
 * is still `shrink-0` so a long name truncates rather than squeezing the
 * figure out.
 *
 * IT DOES NOT SCALE WITH THE TEXT-SIZE PREFERENCE, matching the name it
 * belongs to -- no `.ts`, no `tscale`. The squad plate is a fixed-size plate,
 * which index.css names as the one place text scaling must not go, and the
 * voice mark scaling alone is what forced the `align-self: center` /
 * `items-baseline` pair next door. `leading-none` at 0.62rem puts the line box
 * far under the name's 1.08rem, so the flex line, the plate and the panel
 * PlayerList measures keep their height at every setting. Measured at 0.90,
 * 1.00 and 1.15: identical to the pixel.
 */
function LevelMark({ level }: { level: number }) {
  return (
    <span
      className="font-display leading-none tabular-nums text-[0.62rem] shrink-0"
      style={{ color: 'var(--color-text-dim)', textShadow: 'var(--shadow-text)' }}
    >
      {level}
    </span>
  )
}

/**
 * WHETHER THE SQUAD CAN STILL GET THIS MATE BACK.
 *
 * Owner, 2026-08-30, from the playtest: "I also saw nothing in the squad panel
 * indicating that a revive key had been retrieved", and, once the body and its
 * world plate were gone, "I'm unable to interact with their revive key now and
 * I have no way to know I still have their key."
 *
 * BOTH HALVES OF THAT ARE THE SAME BLINDNESS: a key is an entitlement held by a
 * squad rather than an object anybody carries (br_lib/config/revivekey.lua --
 * "NO SLOT. NO CARRIER."), so there is nothing in an inventory to look at and,
 * after the pickup expires, nothing in the world either. The panel is the only
 * surface that lists the people a key is ABOUT, so it is where the fact lives.
 *
 * ═══ ONE OBJECT, TWO COLOURS, WHICH IS VoiceMark'S VOCABULARY EXACTLY ═══
 *
 * That component draws one silenced-speaker glyph in two shades and lets the
 * colour carry the difference between a state that is merely reported and one
 * the viewer can do something about. This is the same pair:
 *
 *   NOT OURS YET  --color-text-dim. A key exists for this mate: on the ground
 *                 where they fell while the pickup lives, and 25 Volts at an
 *                 ambulance after it expires. Reported, in the caption shade.
 *   HELD          --color-royale-accent. The squad owns it, and a live mate
 *                 walking to any ambulance can spend it. The accent is what
 *                 this panel already uses for something happening now.
 *
 *   NEITHER       no key at all. An absence draws nothing, which is the rule
 *                 every other optional field on this row follows.
 *
 * STATIC, NOT PULSED. `.mate-pulse` and `.mate-talk` mean "this is happening
 * right now"; holding a key is a standing condition that will still be true in
 * two minutes. Animating it would put a fact in competition with a fight.
 *
 * A DRAWN KEY RATHER THAN A WORD, because the six lines in
 * br_lib/config/revivekey.lua are the whole of what this feature is allowed to
 * say and none of them is a panel label -- and because "never add unsolicited
 * UI text" is a standing instruction. INLINE SVG rather than a font or a PNG,
 * for VoiceMark's reasons: `currentColor` is what lets one path follow both
 * tokens through the colourblind remaps, and a glyph font is another entry in
 * fxmanifest's files{} to be forgotten.
 *
 * IT DOES NOT SCALE WITH THE TEXT-SIZE PREFERENCE -- no `.ts`, no `tscale` --
 * matching LevelMark next door rather than VoiceMark. The squad plate is a
 * fixed-size plate, and this mark sits in the stamp group, whose baseline is
 * the row's. `align-self: center` takes it out of baseline alignment entirely
 * (VoiceMark's note has the measurement) and 0.95rem is under the name's
 * 1.08rem line box, so the plate's height is arithmetic rather than luck.
 */
const KEY_PATH =
  'M4.7 3.8a4.2 4.2 0 1 0 0 8.4a4.2 4.2 0 1 0 0-8.4Z'
  + 'M4.7 6.25a1.75 1.75 0 1 1 0 3.5a1.75 1.75 0 1 1 0-3.5Z'
  + 'M7.5 6.9H15.4V12.2H14.2V9.1H12.8V12.2H11.6V9.1H7.5Z'

/**
 * ═══ AND IT IS DRAWN AT NEARLY TWICE THE INK, IN THE SAME BOX HEIGHT ═══
 *
 * "The key inside the squad panel isn't very clear - should be larger."
 *
 * THE BOX WAS SQUARE AND THE KEY IS NOT. KEY_PATH occupies x 0.5..15.4 and
 * y 3.8..12.2 of a 16x16 viewBox -- so a square box spent 47% of its height on
 * empty space above and below the glyph, and `meet` scaled the drawing down to
 * fit the wasted band: 0.89rem by 0.50rem of visible key inside a 0.95rem box.
 * Cropping the viewBox to the path's own extent and giving the span that same
 * aspect draws the SAME path at 1.69rem by 0.95rem -- 1.9x in both directions,
 * about three and a half times the ink -- with no new geometry authored.
 *
 * ═══ 0.95rem STAYS, AND THAT IS THE HALF THAT PROTECTS THE PANEL ═══
 *
 * The header above records the arithmetic: this mark is the only `align-self:
 * center` item in a baseline-aligned group, so it alone sets how far that group
 * reaches below the row's baseline, and a taller one grows every dead and downed
 * plate while live ones stay put -- 0.6px, invisible in review, which is the bug
 * VoiceMark's note next door was written after. The obvious edit is to raise the
 * square box and it is exactly that bug. HEIGHT IS UNCHANGED; only the aspect
 * moved, so the group's cross-extent is the number it has always been.
 */
const KEY_VIEWBOX = '0.5 3.8 14.9 8.4'

function KeyMark({ held }: { held: boolean }) {
  return (
    <span
      className="shrink-0"
      style={{
        display: 'block',
        // See KEY_VIEWBOX: the aspect is the glyph's own now, and the HEIGHT is
        // the one it has always had -- which is what keeps the plate's height
        // arithmetic rather than luck.
        width: '1.685rem',
        height: '0.95rem',
        // See the note above, and VoiceMark's: a flex row with no
        // baseline-aligned item takes its baseline from the bottom edge of its
        // first item. Opting out leaves the stamp beside it as the row's
        // source, which is where it was before this arrived.
        alignSelf: 'center',
        color: held
          ? 'var(--color-royale-accent)'
          : 'var(--color-text-dim)',
      }}
      aria-hidden
    >
      <svg
        viewBox={KEY_VIEWBOX}
        style={{ display: 'block', width: '100%', height: '100%' }}
        aria-hidden
      >
        {/* THE BOW'S HOLE IS WOUND THE OTHER WAY, and the default nonzero fill
            rule is what cuts it out. `evenodd` would have been the obvious
            spelling and it is wrong here: the shaft overlaps the bow by a
            third of a millimetre of viewBox, and under evenodd that sliver
            would punch a notch through the key exactly where it joins. */}
        <path d={KEY_PATH} fill="currentColor" />
      </svg>
    </span>
  )
}

function Row({ m, talking, silent }: {
  m: SquadMember
  talking: boolean
  /** This player's voice carries nothing at all. 'fault' is a silence nobody
   *  asked for and is the VIEWER'S OWN ROW ONLY -- squad mode with no squad is
   *  a fact about this client and about nobody else. 'chosen' is reachable on
   *  any row: the viewer's own, and a squadmate whose beacon says `voiceOff`.
   *  See VoiceMark for what the one published bit is allowed to claim. */
  silent: 'chosen' | 'fault' | null
}) {
  const { phase, flash } = useDeathSequence(m)

  const dead = phase === 'dead'
  const dying = phase === 'dying'
  const downed = phase === 'down'

  // Draining to zero is what the eye actually reads as death; the numbers are
  // already gone from the payload by then, so the phase drives it.
  //
  // ONE SOURCE FOR THE BAR AND THE NUMBER BESIDE IT. The fill is derived from
  // these same two values rather than from the payload, so a number can never
  // disagree with the bar it is standing next to -- including through the
  // death drain, where the payload has already gone to zero and the phase is
  // the only thing that knows what to show.
  const hp = dead || dying ? 0 : Math.max(0, Math.min(100, m.hp))
  const sh = dead || dying ? 0 : Math.max(0, Math.min(100, m.armour ?? 0))

  // A KEY FOR THIS MATE, OR NOT. Read as two explicit comparisons rather than
  // as a truthiness test, because `false` is a real reading on this field and a
  // `&&` would eat it -- see SquadMember.reviveKey in bridge/types.ts.
  const keyHeld = m.reviveKey === true
  const keyOut = m.reviveKey === false

  // A MATE IS A PLATE. Each row is its own object carrying that player's
  // colour on its edge, rather than a stripe inside one shared box -- so a
  // four-stack reads as four people at a glance instead of as a list, and the
  // colour is on the thing rather than beside it.
  //
  // `m.colour` IS THAT PLAYER'S BLIP COLOUR, and both the edge and the tab
  // wear it. It used to be the squad's shared colour, which made all four
  // rows identical -- see the note in br_core/client/state.lua. The tab and
  // the outline being the same colour as the dot on the minimap is the whole
  // point: one teammate, one colour, everywhere they appear.
  return (
    <div
      className="plate relative flex items-center gap-2 px-2 py-1.5"
      style={{
        ['--edgec' as string]: dead ? 'rgba(255,255,255,0.14)' : m.colour,
        ['--plate-fill' as string]: downed
          ? 'rgba(52,20,24,0.92)' : 'rgba(20,23,33,0.90)',
        ['--cut-max' as string]: '0.45rem',
        // ═══ A MATE WHO CAN COME BACK IS NOT DRAWN AS FINISHED ═══
        //
        // 0.34 is what "dead is finished and still" looks like on this panel,
        // and it is right for a mate nobody can do anything about. It is the
        // wrong drawing for one whose key the squad is holding: the row is the
        // most actionable thing on the HUD and it was being faded to a third of
        // its ink, taking the new mark down with it -- the mark exists because
        // the owner "saw nothing", and painting it at 0.34 is a slower way of
        // showing him nothing.
        //
        // SO THE FADE IS THE EXISTING VOCABULARY, USED RATHER THAN ADDED TO.
        // Opacity on this plate already means "is this person still in play".
        // A key is exactly the answer to that question, so it moves the same
        // dial instead of introducing a second one, and the 460ms transition
        // below carries it: a key collected across the map brings its owner's
        // row UP, which is a squad-wide event visible without reading a word.
        //
        // ⚠ 0.7 IS NOT THE OWNER'S NUMBER. He asked to be able to tell; he did
        // not say how bright. It is deliberately short of a live mate's 1 --
        // an OUT row must never read as an alive one, and the OUT stamp is
        // still sitting in it -- and roughly double the finished 0.34, which
        // is the smallest gap that reads as a difference rather than as a
        // rendering artefact.
        opacity: dead ? (keyHeld || keyOut ? 0.7 : 0.34) : 1,
        transition: 'opacity 460ms ease',
      }}
    >
      {flash > 0 && <div key={flash} className="mate-flash" />}

      <span
        className={`w-[0.3rem] self-stretch rounded-sm shrink-0${
          downed ? ' mate-pulse' : ''}`}
        style={{ background: m.colour }}
      />

      <div className="flex-1 min-w-0">
        <div className="flex items-baseline justify-between gap-2">
          {/* `items-baseline`, NOT `items-center`, AND IT IS LOAD-BEARING.
              This group is the first flex item of the row above, which is
              baseline-aligned -- so the group's own baseline decides where the
              whole row sits and how tall the plate is. A flex container with no
              baseline-aligned item inside it synthesises one from its FIRST
              item's bottom edge, and that first item is the voice mark, whose
              size follows the player's text-size preference. Aligning on the
              baseline makes the NAME the source instead; the mark opts out with
              `align-self: center` (see VoiceMark). Measured either way: without
              this pair every downed and dead plate is 0.6px taller at text
              scale 1.15 than at 0.90, for a mark that changes nothing else. */}
          <span className="flex items-baseline gap-1 min-w-0">
            {/* VOICE. Somebody talks and nothing on screen says who (owner,
                2026-08-09); and, since 2026-08-22, whether this player's own
                voice is carrying anything at all.
                The name is where both belong: this panel is already the list
                of who your squad IS, and a mark beside a name needs no legend.

                IT USED TO BE A CONDITIONAL DOT AND IS NOW AN ALWAYS-PRESENT
                SLOT. The old comment claimed the dot "never moves the name
                around as it appears" -- it did, by its own width plus the gap,
                every time somebody started a sentence. A slot that is always
                rendered pins the name's left edge for the life of the panel,
                and it is what lets the glyphs cross-fade instead of blinking.
                See VoiceMark. */}
            <VoiceMark fs="0.72rem" talking={talking} silent={silent} />
            <span className="text-[0.72rem] font-semibold truncate">{m.name}</span>
            {/* NOTHING AT ALL WHEN THE SERVER HAS NOT SAID, which is the same
                rule the bleed clock below follows. A missing level means the
                mate's profile has not come back from the database yet -- so the
                honest rendering is no number, not a `1` that every high-level
                player would watch correct itself a second into the match.

                THE TEST IS A RANGE, NOT A TRUTHINESS CHECK. `m.level &&` would
                also swallow a real 0, and `!= null` would let a NaN through to
                be drawn; levels are 1..100, so that is what is asked. */}
            {typeof m.level === 'number' && m.level >= 1 && (
              <LevelMark level={m.level} />
            )}
          </span>
          {(dead || downed) && (
            // The mark and the stamp travel together on the right edge.
            <span className="flex items-baseline gap-1 shrink-0">
              {/* THE KEY COMES BEFORE THE STAMP, so DOWN and OUT keep the
                  right edge they have always had and the rows stay aligned
                  with each other whether or not a key exists.

                  IT LIVES IN THE STAMP GROUP because it answers the same
                  question the stamp does -- what has happened to this mate --
                  and because that group is the only part of the row a dead
                  plate still draws (the bars and the bleed clock both go).

                  ITS DEADLINE IS NOT HERE ANY MORE. A `142s` sat beside it
                  until 2026-09-02; the owner replaced it with a line along the
                  foot of the card (see KeyDrain, rendered on the plate below).
                  The MARK stays here because it outlives that line: the key is
                  still 25 Volts at an ambulance after the pickup expires, which
                  is the fact this glyph carries and the bar does not.

                  NOTHING AT ALL WHEN THERE IS NO KEY, which is this panel's
                  standing rule for an absent field: see the bleed clock below
                  and the level above. */}
              {(keyHeld || keyOut) && <KeyMark held={keyHeld} />}
              <span
                key={dead ? 'out' : 'down'}
                className="mate-stamp font-display text-[0.62rem] tracking-[0.18em]"
                style={{ color: dead ? 'rgba(255,255,255,0.5)' : 'var(--color-danger)' }}
              >
                {dead ? 'OUT' : 'DOWN'}
              </span>
              {/* NOTHING AT ALL WHEN LUA IS SILENT. Absent means "no deadline
                  on the wire", and the honest rendering of that is no timer --
                  not a zero, not a dash, and not a locally invented clock.
                  See SquadMember.bleedEndsAt in bridge/types.ts. */}
            </span>
          )}
        </div>

        {/* THE CLOCK TAKES THE BARS' PLACE, IT DOES NOT SIT BESIDE THEM.
            Owner, 2026-08-17: "when in DBNO - the squad panel should not show
            health or shield bars, but instead in their place it will show the
            DBNO timer."

            The bars were the wrong thing to draw anyway. A downed mate's health
            is pinned at the downed floor and their shield is irrelevant while
            they bleed -- two bars saying nothing, in the one row where the
            single number that matters is how long you have to reach them.

            The clock also used to render up in the stamp row. Two countdowns
            for one deadline is what this component's own comment warns against,
            so it moved rather than being duplicated.

            THE FIXED HEIGHT IS LOAD-BEARING: without it the row changes height
            the instant a mate goes down and the whole stack jumps. */}
        {!dead && (downed ? (
          <div className="mt-1 flex h-[1.2rem] items-center justify-center">
            {!!m.bleedEndsAt && <RowClock endsAt={m.bleedEndsAt} />}
          </div>
        ) : (
          <div className="mt-1 flex flex-col gap-[0.2rem]">
            <VitalBar value={hp} colour="var(--color-hp)" dying={dying} />
            {/* SHIELD SHOWS ITS ZERO. Vitals hides a zero because its numeral
                sits INSIDE the bar, where a lone 0 floating in an empty track
                reads as a glitch. Out here it is a column entry, and "this
                mate has no shield left" is precisely the thing the owner
                could not see. A blank where a figure belongs would read as
                the panel failing rather than as an answer. */}
            <VitalBar value={sh} colour="var(--color-shield)" dying={dying} />
          </div>
        ))}
      </div>

      {/* HOW LONG IS LEFT TO WALK TO THE BODY -- as a line along this card's
          own foot, which is the owner's design of 2026-09-02.

          ON THE PLATE AND NOT IN THE COLUMN ABOVE, because "the bottom of the
          player's card" is what he asked for and because it is the one place on
          this row that costs no layout: it is absolutely positioned inside a
          plate that is already `position: relative`, so no row changes height
          and no column has to give up width for it. Every other readout here
          had to be fitted into a 13rem line.

          IT DIES WITH THE PICKUP AND THE MARK DOES NOT. `reviveKeyEndsAt`
          arrives only while the pickup is live (client/state.lua gates it on
          the beacon's `live`), so the line appears when a mate goes out and is
          gone the moment there is nothing left on the ground -- while the key
          mark above stays, because the key is still 25 Volts at an ambulance.
          Absent means absent: no empty track, no zero-width bar, which is this
          panel's rule for every optional field on the row.

          IT IS OUTSIDE THE `min-w-0` COLUMN, deliberately: that div is the
          flex child everything else lays out in, and a bar inside it would stop
          at the column's edge rather than crossing the plate. */}
      {!!m.reviveKeyEndsAt && <KeyDrain endsAt={m.reviveKeyEndsAt} />}
    </div>
  )
}

export default function SquadPanel({
  squad, talking = [], voiceSilent = false, voiceChosen = false,
}: {
  squad: SquadPayload
  talking?: number[]
  /** THIS CLIENT's verdict, not anybody else's: nothing can reach it and
   *  nothing it says can leave. Straight off the voice envelope. */
  voiceSilent?: boolean
  /** ...and the player asked for it -- the 'off' preference, or spectating. */
  voiceChosen?: boolean
}) {
  // Unchanged and load-bearing: a solo player has no squad panel, and the
  // party-vs-squad fallback that feeds this channel is what made the worst M2
  // bug. Do not widen this test.
  if (!squad.id || squad.members.length <= 1) return null

  const talkingSet = new Set(talking)

  // THE VIEWER'S OWN ROW IS FOUND BY `you`, which rides on every squad payload
  // precisely because the interface has no other way to know its own server id.
  //
  // ABSENT `you` MARKS THE VIEWER NOBODY, which is the safe failure: an older
  // Lua, or the party payload standing in for a squad, produces a panel with no
  // OWN mark rather than one that has guessed. A squadmate's own bit is
  // unaffected -- it is keyed on that member, not on this comparison.
  const mine = squad.you
  const silence: 'chosen' | 'fault' | null =
    voiceSilent ? (voiceChosen ? 'chosen' : 'fault') : null

  // AND A SQUADMATE'S OWN ROW, WHICH IS NEW AND IS ONE BIT WIDE.
  //
  // Owner, 2026-08-29: "the squad panel works, but doesn't accurately show when
  // others in the squad have 'off' selected." It could not: nothing published
  // it. `voiceOff` now arrives on the squad beacon (br_core server/party.lua),
  // and it is the ONLY voice fact about another player on this payload.
  //
  // IT IS ALWAYS 'chosen', NEVER 'fault'. The two differ by colour and the
  // difference is a claim: 'fault' is --color-danger and means "this is wrong
  // and you can fix it", which is only ever true of the viewer -- they are the
  // one who can open the settings screen. A mate's voice being off is a state
  // of theirs, reported, not an alarm to raise on their behalf; painting it red
  // would teach the player that the colour means nothing, which is the rule
  // VoiceNotice and VoiceMark already draw by.
  //
  // `=== true` RATHER THAN A TRUTHINESS TEST. Absent is a real and common state
  // -- the beacon has not covered this mate yet, or the server predates the
  // field -- and it means "nothing to draw", the same as false. Explicit here
  // keeps those two collapsed onto the same rendering for the right reason
  // instead of by accident.
  const silentFor = (m: SquadMember): 'chosen' | 'fault' | null => {
    if (mine !== undefined && m.src === mine) return silence
    return m.voiceOff === true ? 'chosen' : null
  }

  // No outer .panel: each row is its own plate now, so a shared box around
  // them was a second frame doing nothing but adding an edge.
  return (
    <div className="flex flex-col gap-1">
      {squad.members.map((m) => (
        <Row
          key={m.src}
          m={m}
          talking={talkingSet.has(m.src)}
          silent={silentFor(m)}
        />
      ))}
    </div>
  )
}
