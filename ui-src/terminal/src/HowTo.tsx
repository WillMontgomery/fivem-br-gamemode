import type { ReactElement } from 'react'
import Container from '@cloudscape-design/components/container'
import ContentLayout from '@cloudscape-design/components/content-layout'
import Header from '@cloudscape-design/components/header'
import SpaceBetween from '@cloudscape-design/components/space-between'
import type { Say } from './model'
import { voltsLines } from './Volts'

/**
 * THE HOW-TO PAGE, in the side navigation.
 *
 * Owner, 2026-10-05: "The sidebar should include a how-to page with tips on
 * how to use it, strategic suggestions for use of the tools, etc." The one page
 * allowed to talk strategy, and only in general terms; a function's own page
 * never says how it helps. Every section is a title and a list from the copy
 * block (`howto_<section>_title`, `howto_<section>_body`) -- the squad's
 * words only in a squad match, through the speaker like every other line --
 * and any Volts a line says in the Volts style (round 4, Volts.tsx).
 */
const SECTIONS = ['key', 'terminal', 'rules', 'notices', 'tips'] as const

export function HowTo({ say, currency }: { say: Say; currency: string }): ReactElement {
  return (
    <ContentLayout header={<Header variant="h1">{say('howto_title')}</Header>}>
      <SpaceBetween size="l">
        {SECTIONS.map((s) => (
          <div key={s} className="terminal-raised">
            <Container header={<Header variant="h2">{say(`howto_${s}_title`)}</Header>}>
              <ul className="terminal-howto">
                {voltsLines(say(`howto_${s}_body`), currency).map((p, i) => <li key={i}>{p}</li>)}
              </ul>
            </Container>
          </div>
        ))}
      </SpaceBetween>
    </ContentLayout>
  )
}
