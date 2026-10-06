import type { ReactElement } from 'react'
import Box from '@cloudscape-design/components/box'
import Container from '@cloudscape-design/components/container'
import ContentLayout from '@cloudscape-design/components/content-layout'
import Header from '@cloudscape-design/components/header'
import SpaceBetween from '@cloudscape-design/components/space-between'
import { lines, type Say } from './model'

/**
 * THE PRIVACY PAGE, in the side navigation after How to.
 *
 * Owner, 2026-10-06: a Privacy page, a made-up policy "sponsored by
 * Lifeinvader" that guarantees privacy only to people who don't use the
 * system. His approved words ("Perfect"), verbatim from the copy block: the
 * title (`privacy_title`) over one container of plain text, a paragraph per
 * piece of `privacy_body` -- two. Nothing else is said here.
 */
export function Privacy({ say }: { say: Say }): ReactElement {
  return (
    <ContentLayout header={<Header variant="h1">{say('privacy_title')}</Header>}>
      <div className="terminal-raised">
        <Container>
          <SpaceBetween size="m">
            {lines(say('privacy_body')).map((p, i) => <Box key={i} variant="p">{p}</Box>)}
          </SpaceBetween>
        </Container>
      </div>
    </ContentLayout>
  )
}
