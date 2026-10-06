import type { ReactElement, ReactNode } from 'react'
import ExpandableSection from '@cloudscape-design/components/expandable-section'
import KeyValuePairs from '@cloudscape-design/components/key-value-pairs'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import type { TerminalState } from './bridge'
import { clock, fill, type Say } from './model'

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
 * "MATCH STATS", COLLAPSED (round 2: 'Can you make the match table say "Match
 * stats" and be collapsed by default?'). An expandable container whose header
 * is match_heading; App.tsx holds whether it is open, closed every time the
 * app opens, and kept as the player leaves it while they move between pages.
 *
 * Everything shown is what this player may already know: the match's tag and
 * clock, the storm everyone sees, the HUD's counts, their own squad, their own
 * key, how many terminals are live, and the bounties the lobby was told of.
 * A row whose label (or, for the mode, value) is an empty line is not shown --
 * outside a squad match, the squad's rows.
 */
export function MatchPanel({ state, say, expanded, onExpand }: {
  state: TerminalState
  say: Say
  expanded: boolean
  onExpand: (open: boolean) => void
}): ReactElement {
  const m = state.match
  const none = say('none')
  const dash = '-'

  const squad = m && m.squad.length > 0
    ? (
      <SpaceBetween size="xxs">
        {m.squad.map((mate, i) => (
          <StatusIndicator key={`${i}:${mate.name}`}
            type={mate.state === 'alive' ? 'success' : mate.state === 'downed' ? 'warning' : 'stopped'}>
            {`${mate.name} · ${say(`mate_${mate.state}`)}`}
          </StatusIndicator>
        ))}
      </SpaceBetween>
    )
    : dash

  const storm = m?.storm
  const stormStage = storm && storm.stage !== null
    ? fill(say('storm_stage'), { stage: storm.stage, stages: storm.stages ?? dash })
    : dash
  const sweep = storm && storm.state
    ? `${say(`storm_${storm.state}`)}${storm.state === 'holding' || storm.state === 'shrinking' || storm.state === 'pre'
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

  const mode = m && m.mode ? say(`mode_${m.mode}`) : dash
  const rows: { label: string; value: ReactNode }[] = [
    { label: say('field_match'), value: m ? (m.tag ?? dash) : say('no_match') },
    { label: mode === '' ? '' : say('field_mode'), value: mode },
    { label: say('field_phase'), value: m && m.phase ? say(`phase_${m.phase}`) || dash : dash },
    { label: say('field_time'), value: m ? clock(m.elapsedMs) : dash },
    { label: say('field_storm'), value: stormStage },
    { label: say('field_sweep'), value: sweep },
    { label: say('field_players'), value: m && m.players !== null ? String(m.players) : dash },
    { label: say('field_squads'), value: m && m.squads !== null ? String(m.squads) : dash },
    { label: say('field_squad'), value: squad },
    {
      label: say('field_key'),
      value: (
        <StatusIndicator type={state.keyHeld ? 'success' : 'stopped'}>
          {state.keyHeld ? say('key_held') : say('key_none')}
        </StatusIndicator>
      ),
    },
    {
      label: say('field_squad_key'),
      value: (
        <StatusIndicator type={state.squadUsed ? 'stopped' : 'success'}>
          {state.squadUsed ? say('squad_key_used') : say('squad_key_unused')}
        </StatusIndicator>
      ),
    },
    {
      label: say('field_terminals'),
      value: m && m.terminals
        ? fill(say('terminals_count'), { online: m.terminals.online, total: m.terminals.total })
        : dash,
    },
    { label: say('field_bounty'), value: bounty },
  ]
  const items = rows.filter((r) => r.label !== '')

  return (
    <div className="terminal-raised">
      <ExpandableSection
        variant="container"
        headerText={say('match_heading')}
        expanded={expanded}
        onChange={({ detail }) => onExpand(detail.expanded)}
      >
        <KeyValuePairs columns={4} items={items} />
      </ExpandableSection>
    </div>
  )
}
