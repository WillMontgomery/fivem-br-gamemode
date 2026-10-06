import type { ReactElement } from 'react'
import Box from '@cloudscape-design/components/box'
import Container from '@cloudscape-design/components/container'
import Icon from '@cloudscape-design/components/icon'
import SpaceBetween from '@cloudscape-design/components/space-between'
import type { Say } from './model'

/**
 * THE LOGIN SCREEN: the app opened without a Yubikey.
 *
 * Owner, 2026-10-04 (#396, verbatim): "the computer still opens but stays on
 * a login screen reading: You need a Yubikey to access this system. Search far
 * and wide, and you just might find one." That line is the copy block's
 * `no_key`, under a lock. Nothing else is said, and there is nothing to press:
 * without a key the server would refuse every run anyway.
 *
 * NO APP NAME HERE (round 2). The owner found "some random 'Blitz Terminal'
 * text" on the white space near the top left of this screen -- the breadcrumb
 * trail, which on this page was the app's name alone (App.tsx no longer draws
 * one here) -- and asked for the name to stay only in the top bar, so this
 * card's heading, which said it too, is gone with it.
 */
export function Login({ say }: { say: Say }): ReactElement {
  return (
    <div className="terminal-login">
      <Container>
        <SpaceBetween size="m" alignItems="center">
          {[
            <Icon key="icon" name="lock-private" size="large" />,
            <Box key="line" variant="p" textAlign="center">{say('no_key')}</Box>,
          ]}
        </SpaceBetween>
      </Container>
    </div>
  )
}
