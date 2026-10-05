import { useEffect, useState, type ReactElement } from 'react'
import Alert from '@cloudscape-design/components/alert'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Container from '@cloudscape-design/components/container'
import Header from '@cloudscape-design/components/header'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import { connect, run, type Copy, type FunctionState, type RunResult, type TerminalState } from './bridge'

/**
 * THE FIRST SCREEN: the terminal's functions, whether each can run and why
 * not, and the button that asks.
 *
 * ═══ NOT ONE WORD ON THIS SCREEN IS WRITTEN HERE ═══
 *
 * The owner writes or approves every player-facing line (#396), so every line
 * is a key into the copy br_core sends with the state, out of the one block in
 * br_lib/config/terminals.lua. A key with no line renders as nothing -- never
 * as the key, and never as a default of ours. The keys:
 *
 *   app_heading            over the list
 *   <function id>_name     the function, e.g. storm_reveal_name
 *   available              the status of one that can run
 *   <reason code>          why one cannot, e.g. no_key, squad_used, offline
 *   unavailable            why not, for a code with no line of its own
 *   run                    the button
 *   <function id>_done     after a run the server accepted, e.g. storm_reveal_done
 *
 * ═══ AND NOTHING HERE DECIDES ═══
 *
 * `available` and `reason` are the server's. The button is disabled when the
 * server said no, and while a run is waiting for its answer; pressing it only
 * asks, and the server checks the terminal, the key and the squad again.
 *
 * ═══ CEF 103 (#385) ═══
 *
 * No Spinner and no `loading` anywhere: Cloudscape's spinner animates forever,
 * even under disableMotion, and every frame it animates repaints the whole NUI.
 * A waiting button is disabled instead. Arrays, not Fragments, go into
 * SpaceBetween (React 19). scripts/check-terminal.mjs holds these.
 */
export function App(): ReactElement {
  const [state, setState] = useState<TerminalState | null>(null)
  const [copy, setCopy] = useState<Copy>({})
  const [pending, setPending] = useState<string | null>(null)
  const [result, setResult] = useState<RunResult | null>(null)

  useEffect(
    () =>
      connect({
        state(next, nextCopy) {
          setState(next)
          setCopy(nextCopy)
        },
        result(next) {
          setResult(next)
          setPending(null)
        },
      }),
    [],
  )

  const line = (key: string | null): string => (key !== null ? copy[key] ?? '' : '')

  const ask = (id: string) => {
    setPending(id)
    setResult(null)
    run(id)
  }

  const rows: ReactElement[] = []
  if (result !== null) {
    rows.push(
      <Alert key="result" type={result.ok ? 'success' : 'error'}>
        {result.ok ? line(`${result.functionId}_done`) : line(result.code) || line('unavailable')}
      </Alert>,
    )
  }
  for (const fn of state?.functions ?? []) {
    rows.push(<FunctionRow key={fn.id} fn={fn} line={line} busy={pending !== null} onRun={ask} />)
  }

  return (
    <div className="terminal">
      <Container header={<Header variant="h2">{line('app_heading')}</Header>}>
        <SpaceBetween size="m">{rows}</SpaceBetween>
      </Container>
    </div>
  )
}

interface RowProps {
  fn: FunctionState
  line: (key: string | null) => string
  busy: boolean
  onRun: (id: string) => void
}

function FunctionRow({ fn, line, busy, onRun }: RowProps): ReactElement {
  const why = fn.available ? line('available') : line(fn.reason) || line('unavailable')
  return (
    <div className="terminal-fn" data-function={fn.id}>
      <div className="terminal-fn-text">
        <Box variant="h3" padding="n">
          {line(`${fn.id}_name`)}
        </Box>
        <StatusIndicator type={fn.available ? 'success' : 'stopped'}>{why}</StatusIndicator>
      </div>
      <Button variant="primary" disabled={!fn.available || busy} onClick={() => onRun(fn.id)}>
        {line('run')}
      </Button>
    </div>
  )
}
