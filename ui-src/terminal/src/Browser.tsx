import type { ReactElement } from 'react'
import Button from '@cloudscape-design/components/button'
import Icon from '@cloudscape-design/components/icon'

/**
 * THE BROWSER'S TOOLBAR: back, forward, reload, and the address bar.
 *
 * Owner, 2026-10-05: the window should "look like a web browser, not a
 * terminal". The tab strip above this is the desktop's (cuchi_computer's
 * br.css restyles its window's title bar); this row is the app's, because the
 * history it walks and the address it shows are the app's own navigation --
 * App.tsx holds both, and these buttons only ask it to move.
 *
 * RELOAD REALLY RELOADS: the desktop is asked for the state, the copy and the
 * catalog again, and the page is remounted fresh.
 *
 * The address is a fictional URL for the page (model.ts addressOf), read-only,
 * as a page's address is until somebody types in it -- and there is nowhere
 * else in this app to go.
 */
export function Browser(props: {
  address: string
  canBack: boolean
  canForward: boolean
  onBack: () => void
  onForward: () => void
  onReload: () => void
  labels: { back: string; forward: string; reload: string; address: string }
}): ReactElement {
  const { address, labels } = props
  return (
    <div className="browser-toolbar">
      <div className="browser-buttons">
        <Button variant="icon" iconName="angle-left" ariaLabel={labels.back}
          disabled={!props.canBack} onClick={props.onBack} />
        <Button variant="icon" iconName="angle-right" ariaLabel={labels.forward}
          disabled={!props.canForward} onClick={props.onForward} />
        <Button variant="icon" iconName="refresh" ariaLabel={labels.reload} onClick={props.onReload} />
      </div>
      <div className="browser-address" role="textbox" aria-readonly="true" aria-label={labels.address}>
        <span className="browser-lock">
          <Icon name="lock-private" size="small" />
        </span>
        <span className="browser-url">{address}</span>
      </div>
    </div>
  )
}
