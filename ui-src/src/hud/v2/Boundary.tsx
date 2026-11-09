import { Component, type ReactNode } from 'react'
import { reportError } from '../../bridge/nui'

/**
 * A UI V2 PLACE THAT THROWS DRAWS TODAY'S LINE (#431, #436).
 *
 * Round the hud piece's side of each of App.tsx's three ternaries (the HUD,
 * chat, the notices), and only that side: with the piece off a place is
 * today's line with nothing round it. A render that throws inside the v2
 * layer is reported once, to F8 and the server log as every page error is
 * (bridge/nui.ts reportError), and the place draws `today` -- the same line as
 * its ternary's off side -- for as long as this stays mounted, which is until
 * the hud piece next moves. A broken v2 layer costs the player the Broadcast
 * wipe in that place, and nothing else.
 *
 * SO IT CAN SWAP MID-MATCH, BY DESIGN: the render that throws is the last v2
 * frame that place draws.
 *
 * WHAT IT CANNOT CATCH is an error outside a render: a timer or a listener a
 * presence settles on (ui/broadcast/motion/usePresence.ts) reaches the page's
 * own error sinks (installErrorSinks) and leaves the place as it was.
 *
 * Market v2's door is the shape (screens/marketv2/Gate.tsx), with no chunk to
 * load and today's line, not nothing, to fall back on.
 */
export default class Boundary extends Component<
  {
    /** The place, for the report: `ui v2 hud`, `ui v2 chat`, `ui v2 notices`. */
    what: string
    /** Today's line, as the ternary's off side draws it. */
    today: ReactNode
    children: ReactNode
  },
  { failed: boolean }
> {
  state = { failed: false }
  static getDerivedStateFromError() { return { failed: true } }
  componentDidCatch(err: unknown) { reportError(`ui v2 ${this.props.what}`, err) }
  render() { return this.state.failed ? this.props.today : this.props.children }
}
