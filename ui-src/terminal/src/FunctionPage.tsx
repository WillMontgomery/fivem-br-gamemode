import { useEffect, useRef, useState, type ReactElement } from 'react'
import Badge from '@cloudscape-design/components/badge'
import Box from '@cloudscape-design/components/box'
import Button, { type ButtonProps } from '@cloudscape-design/components/button'
import Container from '@cloudscape-design/components/container'
import ContentLayout from '@cloudscape-design/components/content-layout'
import FormField from '@cloudscape-design/components/form-field'
import Header from '@cloudscape-design/components/header'
import KeyValuePairs from '@cloudscape-design/components/key-value-pairs'
import Modal from '@cloudscape-design/components/modal'
import RadioGroup from '@cloudscape-design/components/radio-group'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import type { FunctionDef, FunctionState } from './bridge'
import { fill, indicatorOf, riskColor, showsSquads, statusOf, type Say } from './model'
import { Squads } from './Squads'
import { voltsLine, voltsLines } from './Volts'

/**
 * ONE FUNCTION'S PAGE, in the shape of Cloudscape's details example.
 *
 * Owner, 2026-10-05: "the details page should tell them what options they
 * have for the card/function, what it does, what risks it holds for them,
 * etc -- just don't tell them how it can help them. That's on them to
 * decide." So, from the copy block: the details (category, status, duration,
 * who it affects, who is told, the cost), what it does, its options as real
 * form controls, and its risks -- the notice every run sends first -- and the
 * Run button. Nothing here says what it is good for.
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
 * RUN WEARS THE FUNCTION'S RISK (round 2: "the Run button - make it the risk
 * color instead"): the same color as its low, medium or high risk badge, in
 * both modes, with the badge's own text color -- terminal.css's
 * `--terminal-run-*` variables, which are the badge's tokens. "SQUADS!"
 * FOLLOWS THE TITLE on a function whose effect reaches the whole squad, in a
 * squad match (round 4, Squads.tsx), and EVERY VOLTS on the page -- the cost,
 * the confirmation -- is in the Volts style (Volts.tsx). NO SHADOW
 * (owner, 2026-10-06: "not sure why these buttons have shadows"): a button
 * sits on its surface, like every control (terminal.css).
 */
export function runStyle(risk: FunctionDef['risk']): ButtonProps.Style {
  const v = (part: string) => `var(--terminal-run-${risk}-${part})`
  const off = (part: string) => `var(--terminal-run-disabled-${part})`
  return {
    root: {
      background: { default: v('bg'), hover: v('bg-hover'), active: v('bg-active'), disabled: off('bg') },
      borderColor: { default: v('bg'), hover: v('bg-hover'), active: v('bg-active'), disabled: off('bg') },
      color: { default: v('text'), hover: v('text'), active: v('text'), disabled: off('text') },
    },
  }
}

export function FunctionPage(props: {
  def: FunctionDef
  fn: FunctionState | undefined
  say: Say
  currency: string
  squadMatch: boolean
  busy: boolean
  onRun: (id: string, options: Record<string, string>) => void
  onConfirmChange: (open: boolean) => void
}): ReactElement {
  const { def, fn, say } = props
  const id = def.id
  const status = statusOf(fn, def)
  const available = status === 'available'
  const [choice, setChoice] = useState<Record<string, string>>(
    () => Object.fromEntries(def.options.map((o) => [o.id, o.default])))
  const [confirm, setConfirmState] = useState(false)
  const setConfirm = (open: boolean) => {
    setConfirmState(open)
    props.onConfirmChange(open)
  }
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
  // THE COST AND THE BOX SAY THE VOLTS IN THE VOLTS STYLE: {volts} is the
  // run's cost, the figure and the word. The amounts are written inside the
  // voltsLine call, where check-terminal T12 (e) can see where they go.
  const cost = def.cost > 0
    ? voltsLine(say('cost_line_volts'), currency, { volts: def.cost })
    : voltsLine(say('cost_line'), currency)
  const body = def.cost > 0
    ? voltsLine(say('confirm_body_volts'), currency, { volts: def.cost })
    : voltsLine(say('confirm_body'), currency)

  const details = [
    { label: say('field_category'), value: say(`category_${def.category}`) },
    {
      label: say('field_status'),
      value: (
        <SpaceBetween size="xxs">
          {[
            <StatusIndicator key="s" type={indicatorOf(status)}>{say(`status_${status}`)}</StatusIndicator>,
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

  const risks = [...voltsLines(say('risk_notice'), currency), ...voltsLines(say(`${id}_risks`), currency)]

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
  if (def.options.length > 0) {
    sections.push(
      <div key="options" className="terminal-raised">
        <Container header={<Header variant="h2">{say('options_heading')}</Header>}>
          <SpaceBetween size="l">
            {def.options.map((o) => (
              <FormField key={o.id} label={say(`${id}_opt_${o.id}`)}>
                <RadioGroup
                  value={choice[o.id] ?? o.default}
                  onChange={({ detail }) => setChoice({ ...choice, [o.id]: detail.value })}
                  items={o.choices.map((c) => ({
                    value: c,
                    label: say(`${id}_opt_${o.id}_${c}`),
                    description: say(`${id}_opt_${o.id}_${c}_desc`) || undefined,
                    disabled: !available,
                  }))}
                />
              </FormField>
            ))}
          </SpaceBetween>
        </Container>
      </div>,
    )
  }
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
      <Modal
        visible={confirm}
        onDismiss={() => setConfirm(false)}
        closeAriaLabel={say('aria_close')}
        header={fill(say('confirm_title'), { name })}
        footer={
          <Box float="right">
            <SpaceBetween direction="horizontal" size="xs">
              {[
                <Button key="no" variant="link" onClick={() => setConfirm(false)}>{say('confirm_no')}</Button>,
                <Button key="yes" variant="primary" style={runStyle(def.risk)} disabled={!available || props.busy}
                  onClick={() => {
                    setConfirm(false)
                    props.onRun(id, choice)
                  }}>
                  {say('confirm_yes')}
                </Button>,
              ]}
            </SpaceBetween>
          </Box>
        }
      >
        {body}
      </Modal>
    </ContentLayout>
  )
}
