import type { ReactElement } from 'react'
import Container from '@cloudscape-design/components/container'
import Header from '@cloudscape-design/components/header'
import KeyValuePairs from '@cloudscape-design/components/key-value-pairs'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import type { Copy, TerminalState } from './bridge'
import { clock, fill, line } from './model'

/**
 * THE MATCH, REALTIME: the details panel over the cards.
 *
 * Owner, 2026-10-05: "at the top of the page it should have a details table
 * which shows realtime match info", like Cloudscape's details example. The
 * server pushes the whole state once a second while the computer is open
 * (TERMINAL_INFO), so every value here is at most a second old and nothing on
 * this page runs a clock of its own -- no timer, no animation, no repaint
 * between pushes.
 *
 * Everything shown is what this player may already know: the match's tag and
 * clock, the storm everyone sees, the HUD's counts, their own squad, their own
 * key, how many terminals are live, and the bounties the lobby was told of.
 */
export function MatchPanel({ state, copy }: { state: TerminalState; copy: Copy }): ReactElement {
  const L = (k: string) => line(copy, k)
  const m = state.match
  const none = L('none')
  const dash = '-'

  const squad = m && m.squad.length > 0
    ? (
      <SpaceBetween size="xxs">
        {m.squad.map((mate, i) => (
          <StatusIndicator key={`${i}:${mate.name}`}
            type={mate.state === 'alive' ? 'success' : mate.state === 'downed' ? 'warning' : 'stopped'}>
            {`${mate.name} · ${L(`mate_${mate.state}`)}`}
          </StatusIndicator>
        ))}
      </SpaceBetween>
    )
    : dash

  const storm = m?.storm
  const stormStage = storm && storm.stage !== null
    ? fill(L('storm_stage'), { stage: storm.stage, stages: storm.stages ?? dash })
    : dash
  const sweep = storm && storm.state
    ? `${L(`storm_${storm.state}`)}${storm.state === 'holding' || storm.state === 'shrinking' || storm.state === 'pre'
      ? ` · ${clock(storm.leftMs)}` : ''}`
    : dash

  const bounty = m && m.bounties.length > 0
    ? (
      <SpaceBetween size="xxs">
        {m.bounties.map((b, i) => (
          <StatusIndicator key={`${i}:${b.name}`} type="warning">
            {`${b.name} · ${clock(b.leftMs)}`}
          </StatusIndicator>
        ))}
      </SpaceBetween>
    )
    : none

  const items = [
    { label: L('field_match'), value: m ? (m.tag ?? dash) : L('no_match') },
    { label: L('field_mode'), value: m && m.mode ? L(`mode_${m.mode}`) || dash : dash },
    { label: L('field_phase'), value: m && m.phase ? L(`phase_${m.phase}`) || dash : dash },
    { label: L('field_time'), value: m ? clock(m.elapsedMs) : dash },
    { label: L('field_storm'), value: stormStage },
    { label: L('field_sweep'), value: sweep },
    { label: L('field_players'), value: m && m.players !== null ? String(m.players) : dash },
    { label: L('field_squads'), value: m && m.squads !== null ? String(m.squads) : dash },
    { label: L('field_squad'), value: squad },
    {
      label: L('field_key'),
      value: (
        <StatusIndicator type={state.keyHeld ? 'success' : 'stopped'}>
          {state.keyHeld ? L('key_held') : L('key_none')}
        </StatusIndicator>
      ),
    },
    {
      label: L('field_squad_key'),
      value: (
        <StatusIndicator type={state.squadUsed ? 'stopped' : 'success'}>
          {state.squadUsed ? L('squad_key_used') : L('squad_key_unused')}
        </StatusIndicator>
      ),
    },
    {
      label: L('field_terminals'),
      value: m && m.terminals
        ? fill(L('terminals_count'), { online: m.terminals.online, total: m.terminals.total })
        : dash,
    },
    { label: L('field_bounty'), value: bounty },
  ]

  return (
    <Container header={<Header variant="h2">{L('match_heading')}</Header>}>
      <KeyValuePairs columns={4} items={items} />
    </Container>
  )
}
