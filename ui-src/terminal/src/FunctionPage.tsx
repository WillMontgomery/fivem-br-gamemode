import { useState, type ReactElement } from 'react'
import Badge from '@cloudscape-design/components/badge'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Container from '@cloudscape-design/components/container'
import ContentLayout from '@cloudscape-design/components/content-layout'
import FormField from '@cloudscape-design/components/form-field'
import Header from '@cloudscape-design/components/header'
import KeyValuePairs from '@cloudscape-design/components/key-value-pairs'
import Modal from '@cloudscape-design/components/modal'
import RadioGroup from '@cloudscape-design/components/radio-group'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import type { Copy, FunctionDef, FunctionState } from './bridge'
import { fill, indicatorOf, line, lines, riskColor, statusOf } from './model'

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
 * cannot run and while a run waits for its answer; a box confirms first,
 * because a run spends the key and the squad's one use; the server checks
 * the terminal, the key, the squad and every option again.
 */
export function FunctionPage(props: {
  def: FunctionDef
  fn: FunctionState | undefined
  copy: Copy
  busy: boolean
  onRun: (id: string, options: Record<string, string>) => void
  onConfirmChange: (open: boolean) => void
}): ReactElement {
  const { def, fn, copy } = props
  const L = (k: string) => line(copy, k)
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

  const name = L(`${id}_name`)
  const reason = !available && fn && fn.reason ? (L(fn.reason) || L('unavailable')) : ''

  const details = [
    { label: L('field_category'), value: L(`category_${def.category}`) },
    {
      label: L('field_status'),
      value: (
        <SpaceBetween size="xxs">
          {[
            <StatusIndicator key="s" type={indicatorOf(status)}>{L(`status_${status}`)}</StatusIndicator>,
            ...(reason !== '' ? [<Box key="r" variant="small">{reason}</Box>] : []),
          ]}
        </SpaceBetween>
      ),
    },
    { label: L('card_risk'), value: <Badge color={riskColor(def.risk)}>{L(`risk_${def.risk}`)}</Badge> },
    { label: L('field_duration'), value: L(`${id}_duration`) },
    { label: L('field_affects'), value: L(`${id}_affects`) },
    { label: L('field_notified'), value: L(`${id}_notified`) },
    { label: L('field_cost'), value: L('cost_line') },
  ]

  const risks = [L('risk_notice'), ...lines(L(`${id}_risks`))].filter((s) => s !== '')

  const sections: ReactElement[] = [
    <Container key="details" header={<Header variant="h2">{L('details_heading')}</Header>}>
      <KeyValuePairs columns={3} items={details} />
    </Container>,
    <Container key="what" header={<Header variant="h2">{L('what_heading')}</Header>}>
      <SpaceBetween size="s">
        {lines(L(`${id}_what`)).map((p, i) => <Box key={i} variant="p">{p}</Box>)}
      </SpaceBetween>
    </Container>,
  ]
  if (def.options.length > 0) {
    sections.push(
      <Container key="options" header={<Header variant="h2">{L('options_heading')}</Header>}>
        <SpaceBetween size="l">
          {def.options.map((o) => (
            <FormField key={o.id} label={L(`${id}_opt_${o.id}`)}>
              <RadioGroup
                value={choice[o.id] ?? o.default}
                onChange={({ detail }) => setChoice({ ...choice, [o.id]: detail.value })}
                items={o.choices.map((c) => ({
                  value: c,
                  label: L(`${id}_opt_${o.id}_${c}`),
                  description: L(`${id}_opt_${o.id}_${c}_desc`) || undefined,
                  disabled: !available,
                }))}
              />
            </FormField>
          ))}
        </SpaceBetween>
      </Container>,
    )
  }
  sections.push(
    <Container key="risks" header={<Header variant="h2">{L('risks_heading')}</Header>}>
      <ul className="terminal-risks">
        {risks.map((r, i) => <li key={i}>{r}</li>)}
      </ul>
    </Container>,
  )

  return (
    <ContentLayout
      header={
        <Header
          variant="h1"
          description={L(`${id}_summary`)}
          actions={
            <Button variant="primary" disabled={!available || props.busy} onClick={() => setConfirm(true)}>
              {L('run')}
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
        closeAriaLabel={L('aria_close')}
        header={fill(L('confirm_title'), { name })}
        footer={
          <Box float="right">
            <SpaceBetween direction="horizontal" size="xs">
              {[
                <Button key="no" variant="link" onClick={() => setConfirm(false)}>{L('confirm_no')}</Button>,
                <Button key="yes" variant="primary" disabled={!available || props.busy}
                  onClick={() => {
                    setConfirm(false)
                    props.onRun(id, choice)
                  }}>
                  {L('confirm_yes')}
                </Button>,
              ]}
            </SpaceBetween>
          </Box>
        }
      >
        {L('confirm_body')}
      </Modal>
    </ContentLayout>
  )
}
