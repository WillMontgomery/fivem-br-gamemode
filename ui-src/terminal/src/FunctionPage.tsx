import { useEffect, useRef, useState, type ReactElement } from 'react'
import Badge from '@cloudscape-design/components/badge'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Container from '@cloudscape-design/components/container'
import ContentLayout from '@cloudscape-design/components/content-layout'
import Header from '@cloudscape-design/components/header'
import KeyValuePairs from '@cloudscape-design/components/key-value-pairs'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import type { FunctionDef, FunctionState, Mate, PickResult, Rarity, Spot } from './bridge'
import { costFor, indicatorOf, riskColor, risksOf, showsSquads, statusOf, statusText, type Say } from './model'
import { RunBox, runStyle } from './RunBox'
import { Squads } from './Squads'
import { voltsLine, voltsLines } from './Volts'

/**
 * ONE FUNCTION'S PAGE, in the shape of Cloudscape's details example.
 *
 * Owner, 2026-10-05: "the details page should tell them what options they
 * have for the card/function, what it does, what risks it holds for them,
 * etc -- just don't tell them how it can help them. That's on them to
 * decide." So, from the copy block: the details (category, status, duration,
 * who it affects, who is told, the cost), what it does -- which names the
 * options it takes -- and its risks -- the notice every run sends first -- and
 * the Run button. Nothing here says what it is good for.
 *
 * THE OPTIONS ARE ASKED FOR IN THE CONFIRM BOX, NOT HERE (round 6, owner
 * 2026-10-07: "We need to move all required options/inputs to be part of the
 * "confirm" modal. We should explain what options exist in the description,
 * but much like we do location selection today that should be in the confirm
 * modal."). RunBox.tsx is that box; this page keeps the choices made in it
 * while it is up, so the cost line here says the price of what was chosen.
 *
 * ITS STATUS IS THE REAL REASON (round 6: "Yes please say the real reason"):
 * a tool not available now says the rule that stops it (model.ts
 * statusText), and the full line beneath it.
 *
 * RUN ONLY ASKS. The button is disabled when the server says the function
 * cannot run and while a run of this player's is waiting or loading; a box
 * confirms first, because a run spends the key, the squad's one use and --
 * for the most powerful functions -- Volts (the cost line and the box both
 * say how many, round 2); the server checks the terminal, the key, the squad,
 * every option and the balance again. RUN IS PRESSABLE WHATEVER THE BALANCE:
 * a run the Volts cannot cover is refused by the server, which says the cost
 * and the balance (no_volts).
 *
 * A RUN AT A SPOT (round 4: Storm control, Supply drop; round 6: Power
 * outage's own area) HAS A STEP IN ITS BOX: "Set location" hides the computer
 * and opens the big map (the desktop and br_core's client do that), and the
 * box comes back showing the place picked with Run enabled; the run carries
 * the spot, and the server decides what it means.
 *
 * RUN WEARS THE FUNCTION'S RISK (RunBox.tsx `runStyle`). "SQUADS!" FOLLOWS
 * THE TITLE on a function whose effect reaches the whole squad, in a squad
 * match (round 4, Squads.tsx), and EVERY VOLTS on the page -- the cost, the
 * confirmation -- is in the Volts style (Volts.tsx). NO SHADOW (owner,
 * 2026-10-06: "not sure why these buttons have shadows"): a button sits on
 * its surface, like every control (terminal.css).
 */

export function FunctionPage(props: {
  def: FunctionDef
  fn: FunctionState | undefined
  say: Say
  currency: string
  squadMatch: boolean
  busy: boolean
  onRun: (id: string, options: Record<string, string>, at: Spot | null) => void
  onConfirmChange: (open: boolean) => void
  /** "Set location": ask for a spot on the big map (round 4). */
  onPick: (id: string) => void
  /** The last map pick's answer, numbered so each is taken once. */
  picked: { seq: number; result: PickResult } | null
  /** The standing teammates an option may name (round 5). */
  mates: Mate[]
  /** The loot rarities, as the game colors them (round 6: Gear Up's items). */
  rarities: Rarity[]
}): ReactElement {
  const { def, fn, say } = props
  const id = def.id
  const status = statusOf(fn, def)
  const available = status === 'available'
  const [choice, setChoice] = useState<Record<string, string>>(
    () => Object.fromEntries(def.options.map((o) => [o.id, o.default])))
  const [confirm, setConfirmState] = useState(false)
  // THE SPOT PICKED ON THE BIG MAP (round 4, owner 2026-10-06: "the confirm
  // button is greyed out until they select a "set location" button"; spelling-ok: his words): a
  // run at a spot (model.ts needsSpot) has a step in its box, "Set location",
  // and Run waits for a spot. Every opening of the box starts with none; a
  // pick that came back with no spot (no waypoint set when the map closed)
  // goes back to none; "Set location" again picks again.
  const [spot, setSpot] = useState<{ at: Spot; place: string } | null>(null)
  const setConfirm = (open: boolean) => {
    if (open) setSpot(null)
    setConfirmState(open)
    props.onConfirmChange(open)
  }
  // Only an answer that arrives after this page is up, and for this function.
  const seenPick = useRef(props.picked ? props.picked.seq : 0)
  useEffect(() => {
    const p = props.picked
    if (!p || p.seq === seenPick.current) return
    seenPick.current = p.seq
    if (p.result.functionId !== id) return
    setSpot(p.result.at ? { at: p.result.at, place: p.result.place } : null)
  }, [props.picked, id])
  // THE BOX GOES WITH ITS PAGE. A page load started before the box opened
  // (owner, 2026-10-06: every navigation loads for 1-3 s, and the page stays
  // up meanwhile) can end with the box still up; App.tsx must then hear it
  // closed, or Escape would wait on a box that is gone. On unmount only: the
  // latest handler is read through a ref, since App passes a new one every
  // render.
  const confirmChange = useRef(props.onConfirmChange)
  confirmChange.current = props.onConfirmChange
  useEffect(() => () => confirmChange.current(false), [])

  const name = say(`${id}_name`)
  const currency = props.currency
  const reason = !available && fn && fn.reason ? (say(fn.reason) || say('unavailable')) : ''
  // THE COST SAYS THE VOLTS IN THE VOLTS STYLE: {volts} is the run's cost,
  // the figure and the word -- THIS run's, by the choices made in the box
  // (round 5: costBy). The amounts are written inside the voltsLine call,
  // where check-terminal T12 (e) can see where they go.
  const price = costFor(def, choice)
  const cost = price > 0
    ? voltsLine(say('cost_line_volts'), currency, { volts: price })
    : voltsLine(say('cost_line'), currency)

  const details = [
    { label: say('field_category'), value: say(`category_${def.category}`) },
    {
      label: say('field_status'),
      value: (
        <SpaceBetween size="xxs">
          {[
            <StatusIndicator key="s" type={indicatorOf(status)}>{statusText(fn, def, say)}</StatusIndicator>,
            ...(reason !== '' ? [<Box key="r" variant="small">{voltsLine(reason, currency)}</Box>] : []),
          ]}
        </SpaceBetween>
      ),
    },
    { label: say('card_risk'), value: <Badge color={riskColor(def.risk)}>{say(`risk_${def.risk}`)}</Badge> },
    { label: say('field_duration'), value: voltsLine(say(`${id}_duration`), currency) },
    { label: say('field_affects'), value: voltsLine(say(`${id}_affects`), currency) },
    { label: say('field_notified'), value: voltsLine(say(`${id}_notified`), currency) },
    { label: say('field_cost'), value: cost },
  ]

  // risk_notice first (left out for a quiet row), then its own lines, each in
  // the Volts style should it ever say Volts.
  const risks = risksOf(def, say).map((r) => voltsLine(r, currency))

  const sections: ReactElement[] = [
    <div key="details" className="terminal-raised">
      <Container header={<Header variant="h2">{say('details_heading')}</Header>}>
        <KeyValuePairs columns={3} items={details} />
      </Container>
    </div>,
    <div key="what" className="terminal-raised">
      <Container header={<Header variant="h2">{say('what_heading')}</Header>}>
        <SpaceBetween size="s">
          {voltsLines(say(`${id}_what`), currency).map((p, i) => <Box key={i} variant="p">{p}</Box>)}
        </SpaceBetween>
      </Container>
    </div>,
  ]
  sections.push(
    <div key="risks" className="terminal-raised">
      <Container header={<Header variant="h2">{say('risks_heading')}</Header>}>
        <ul className="terminal-risks">
          {risks.map((r, i) => <li key={i}>{r}</li>)}
        </ul>
      </Container>
    </div>,
  )

  return (
    <ContentLayout
      header={
        <Header
          variant="h1"
          description={voltsLine(say(`${id}_summary`), currency)}
          info={showsSquads(def, props.squadMatch) ? <Squads say={say} /> : undefined}
          actions={
            <Button variant="primary" style={runStyle(def.risk)} disabled={!available || props.busy}
              onClick={() => setConfirm(true)}>
              {say('run')}
            </Button>
          }
        >
          {name}
        </Header>
      }
    >
      <SpaceBetween size="l">{sections}</SpaceBetween>
      <RunBox
        def={def}
        say={say}
        currency={currency}
        visible={confirm}
        enabled={available && !props.busy}
        choice={choice}
        onChoice={setChoice}
        mates={props.mates}
        rarities={props.rarities}
        spot={spot}
        onPick={() => {
          setSpot(null)
          props.onPick(id)
        }}
        onRun={(options, at) => {
          setConfirm(false)
          props.onRun(id, options, at)
        }}
        onCancel={() => setConfirm(false)}
      />
    </ContentLayout>
  )
}
