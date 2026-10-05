import type { ReactElement } from 'react'
import Container from '@cloudscape-design/components/container'
import ContentLayout from '@cloudscape-design/components/content-layout'
import Header from '@cloudscape-design/components/header'
import SpaceBetween from '@cloudscape-design/components/space-between'
import type { Copy } from './bridge'
import { line, lines } from './model'

/**
 * THE HOW-TO PAGE, in the side navigation.
 *
 * Owner, 2026-10-05: "The sidebar should include a how-to page with tips on
 * how to use it, strategic suggestions for use of the tools, etc." The one page
 * allowed to talk strategy, and only in general terms; a function's own page
 * never says how it helps. Every section is a title and a list from the copy
 * block (`howto_<section>_title`, `howto_<section>_body`).
 */
const SECTIONS = ['key', 'terminal', 'rules', 'notices', 'tips'] as const

export function HowTo({ copy }: { copy: Copy }): ReactElement {
  const L = (k: string) => line(copy, k)
  return (
    <ContentLayout header={<Header variant="h1">{L('howto_title')}</Header>}>
      <SpaceBetween size="l">
        {SECTIONS.map((s) => (
          <Container key={s} header={<Header variant="h2">{L(`howto_${s}_title`)}</Header>}>
            <ul className="terminal-howto">
              {lines(L(`howto_${s}_body`)).map((p, i) => <li key={i}>{p}</li>)}
            </ul>
          </Container>
        ))}
      </SpaceBetween>
    </ContentLayout>
  )
}
