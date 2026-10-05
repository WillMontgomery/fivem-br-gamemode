import type { ReactElement } from 'react'
import Box from '@cloudscape-design/components/box'
import Container from '@cloudscape-design/components/container'
import Icon from '@cloudscape-design/components/icon'
import SpaceBetween from '@cloudscape-design/components/space-between'
import type { Copy } from './bridge'
import { line } from './model'

/**
 * THE LOGIN SCREEN: a computer opened without a Yubikey.
 *
 * Owner, 2026-10-04 (#396, verbatim): "the computer still opens but stays on
 * a login screen reading: You need a Yubikey to access this system. Search far
 * and wide, and you just might find one." That line is the copy block's
 * `no_key`; the heading is the app's name. Nothing else is said, and there is
 * nothing to press: without a key the server would refuse every run anyway.
 */
export function Login({ copy }: { copy: Copy }): ReactElement {
  return (
    <div className="terminal-login">
      <Container>
        <SpaceBetween size="m" alignItems="center">
          {[
            <Icon key="icon" name="lock-private" size="large" />,
            <Box key="title" variant="h1" textAlign="center">{line(copy, 'app_title')}</Box>,
            <Box key="line" variant="p" textAlign="center">{line(copy, 'no_key')}</Box>,
          ]}
        </SpaceBetween>
      </Container>
    </div>
  )
}
