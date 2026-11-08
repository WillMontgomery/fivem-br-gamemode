/**
 * UI V2 ON THE PAGE (#436): which of its pieces this machine holds.
 *
 * br_ui/client/uiv2.lua sends the `uiv2` envelope as the page reports its
 * environment -- just before br:ui:ready, ahead of every replay -- and on every
 * move of the answer br_core's client holds: in the lobby, as a match starts,
 * or as a first answer, taken in any state (after a `restart br_core`,
 * mid-match too). The store keeps it (`uiv2`, every piece off until told), and
 * each piece reads its own with useUIv2 (ui/useUIv2.ts).
 *
 * SUBSCRIBED AT MODULE LOAD, NOT IN A COMPONENT. Lua's answer to the
 * environment report can land before React has mounted, and the dispatcher
 * drops an envelope nobody is subscribed to (bridge/nui.ts). A subscription in
 * an effect could lose the one push a page load gets and leave every piece off
 * until the next move -- after a br_ui restart mid-match, the rest of the
 * match. installDiag subscribes `diag` for the same reason.
 * scripts/test-uiv2.mjs pins it.
 */

import { subscribe } from './nui'
import { useUi } from '../store'
import type { UIv2Payload } from './types'

let installed = false

/** Called once, from main.tsx, before the page reports its environment. */
export function installUiv2(): void {
  if (installed) return
  installed = true
  subscribe('uiv2', (d) => useUi.getState().setUIv2(d as UIv2Payload | null | undefined))
}
