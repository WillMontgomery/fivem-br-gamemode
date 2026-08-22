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
 * whom, and why a squadmate's own mute state is not one of the things it can --
 * is argued in full in hud/VoiceMark.tsx. Nothing new is published for it.
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
 * ...AND A DECISION NEEDS A NUMBER. Two of the three things the owner could not
 * read off this panel in the playtest were quantities: how long a downed mate
 * has left, and what a mate's health and shield actually are. Both are now
 * numerals rather than lengths -- see BleedClock and VitalBar below. A bar
 * answers "roughly how much?" at a glance and that is all it will ever answer;
 * "can I get there in time" and "is he one shot from down" are questions with
 * digits in them.
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
 * HOW LONG A DOWNED MATE HAS LEFT.
 *
 * Owner, from the playtest: "There's no way for team mates to see how much time
 * is left on DBNO players." A squad's whole decision -- push the pickup or take
 * the fight first -- is a question about this number, and the only player who
 * could see it was the one who could do nothing with it.
 *
 * THE SAME NUMBER THE DOWNED PLAYER IS WATCHING, by construction: same field,
 * same clock, same `Math.ceil(left / 1000)` and the same trailing `s` as
 * DbnoOverlay. Two countdowns for one deadline that round differently would
 * have a squad and their downed mate reading two different answers out loud.
 *
 * `bleedEndsAt` is a SERVER timestamp, so it is compared to
 * `Date.now() + clockOffset` -- the rule StormBar, WarmupTimer and DbnoOverlay
 * already follow. Against a bare Date.now() it is wrong by however far the two
 * clocks happen to sit apart, which is a number nobody can predict and
 * everybody would report as a broken timer.
 *
 * WRITTEN STRAIGHT TO THE NODE, exactly as DbnoOverlay does it, because the
 * alternative is re-rendering a plate several times a second to move two
 * digits -- and a squad can hold three of these at once.
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
function BleedClock({ endsAt, big }: { endsAt: number; big?: boolean }) {
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
      // `big` is the bars' slot, where this is the row's only number and
      // should read as such. 0.72rem is the corner-stamp size it had when it
      // shared a line with the state word.
      className={`font-display leading-none tabular-nums shrink-0 ${
        big ? 'text-[1.05rem]' : 'text-[0.72rem]'
      }`}
      style={{ color: 'var(--color-danger)', textShadow: 'var(--shadow-text)' }}
    >
      --
    </span>
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

function Row({ m, talking, silent }: {
  m: SquadMember
  talking: boolean
  /** Non-null on the VIEWER'S OWN ROW ONLY, and only while their voice carries
   *  nothing at all. See VoiceMark for why it cannot be anybody else's. */
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
        opacity: dead ? 0.34 : 1,
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
          </span>
          {(dead || downed) && (
            // The stamp and the clock travel together on the right edge. The
            // clock is deliberately NOT inside the stamp: .mate-stamp is a
            // scale animation that replays on every state change, and a
            // countdown living inside it would pop once a second.
            <span className="flex items-baseline gap-1 shrink-0">
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
            {!!m.bleedEndsAt && <BleedClock endsAt={m.bleedEndsAt} big />}
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

  // THE SILENCE MARK GOES ON ONE ROW AND ONLY ONE, and `you` is how the row is
  // found. It rides on every squad payload precisely because the interface has
  // no other way to know its own server id.
  //
  // ABSENT `you` MARKS NOBODY, which is the safe failure: an older Lua, or the
  // party payload standing in for a squad, produces a panel with no mark rather
  // than one that has guessed.
  const mine = squad.you
  const silence: 'chosen' | 'fault' | null =
    voiceSilent ? (voiceChosen ? 'chosen' : 'fault') : null

  // No outer .panel: each row is its own plate now, so a shared box around
  // them was a second frame doing nothing but adding an edge.
  return (
    <div className="flex flex-col gap-1">
      {squad.members.map((m) => (
        <Row
          key={m.src}
          m={m}
          talking={talkingSet.has(m.src)}
          silent={mine !== undefined && m.src === mine ? silence : null}
        />
      ))}
    </div>
  )
}
