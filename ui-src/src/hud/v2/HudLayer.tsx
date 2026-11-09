import { useMemo, useSyncExternalStore } from 'react'
import { PresenceScope, QuickHide } from '../../ui/broadcast'
import { isCovered, onCoverReported } from '../../bridge/cover'
import { useUi } from '../../store'
import { AWAY_ATTR } from '../../tutorial/progress'
import Chat from '../../chat/Chat'
import Notices from '../Notices'
import { Anchor, ScopeFloor } from './Anchor'
import { LAST_TURN, PRESET, TURNS, registerRootPreset } from './choreo'
import HudV2 from './HudV2'
import './hud2.css'

/**
 * UI V2'S HUD AS APP MOUNTS IT (#431, #436): one export for each of the three
 * places App.tsx draws today's HUD, chat and notices, so that with the hud
 * piece on each place draws its v2 twin and nothing else moves. App takes
 * each by one ternary on useUIv2('hud'), its off side today's line, and its v2
 * side inside ./Boundary.tsx, which draws today's line instead if this throws.
 *
 * EACH ONE IS THE SAME THREE LAYERS, round its own want:
 *
 *   PresenceScope  hold={the curtain covered}  THE PRESET IS NAMED HERE
 *     QuickHide    our pause menu              150 ms each way, never a replay
 *       PresenceScope  want={...}              the HUD, chat, or notices
 *
 * and a root of its own, which carries `bc-kit` (the kit's tokens are declared
 * there and nowhere else) and `hud-v2` (every rule of ./hud2.css is scoped
 * under it).
 *
 * GTA'S MAP AND MENUS ARE APP'S UI GATE, AS TODAY: its 120 ms fade stays round
 * everything, with the kit's quick hide nested inside it. And the HUD hides on
 * that edge alone: `hud.paused`, which trails it by up to a push each way,
 * gates nothing here but the store's own notice queue, so chat, notices and
 * the HUD come back together.
 *
 * THE CURTAIN HOLDS, IT DOES NOT HIDE. The hold is the curtain fully drawn, as
 * the curtain itself last reported it to Lua (bridge/cover.ts): the HUD the
 * curtain rises over (a leave mid-match) stays on screen until the curtain
 * covers it, and the warmup HUD that arrives under it waits, held, until the
 * curtain starts to lift, and the reveal plays as it does.
 *
 * App's routes, its single mounts (the rescue clock, the death word, the
 * verdict, the curtain) and its pause menu stay where they are.
 */

/** The curtain covered, as it was last reported to Lua: a read, and a
 *  re-render on each report. */
const onCurtain = (fn: () => void) => onCoverReported((kind) => { if (kind === 'curtain') fn() })
const curtainNow = () => isCovered('curtain')
function useCurtainCovered(): boolean {
  return useSyncExternalStore(onCurtain, curtainNow)
}

/** Our pause menu is up: the quick hide round all three. */
function usePauseOpen(): boolean {
  return useUi((s) => s.focus === 'pause')
}

/** App.tsx's HUD place: the HUD itself, wanted while `up` (App's hudUp). */
export function HudLayer({ up }: { up: boolean }) {
  const held = useCurtainCovered()
  const paused = usePauseOpen()
  // The root's timing, from the wipe's turns: registered once, the first time
  // the v2 HUD is drawn.
  const rootPreset = useMemo(() => registerRootPreset(TURNS, PRESET), [])
  return (
    <div className="bc-kit hud-v2">
      <PresenceScope hold={held} preset={PRESET}>
        <QuickHide hidden={paused}>
          <PresenceScope want={up}>
            <HudV2 rootPreset={rootPreset} paused={paused} />
          </PresenceScope>
        </QuickHide>
      </PresenceScope>
    </div>
  )
}

/** App.tsx's chat place. Chat stays through the bus ride and the ambulance
 *  and leaves with the match; its column is fixed, so its anchor is
 *  full-stage. `barsVisible` is today's (App's hudUp). */
export function ChatLayer({ want, barsVisible }: { want: boolean; barsVisible: boolean }) {
  const held = useCurtainCovered()
  const paused = usePauseOpen()
  return (
    <div className="bc-kit hud-v2" {...(held || paused ? { [AWAY_ATTR]: 'hud-chat' } : {})}>
      <PresenceScope hold={held} preset={PRESET}>
        <QuickHide hidden={paused}>
          <PresenceScope want={want}>
            <ScopeFloor order={LAST_TURN} />
            <Anchor id="chat">
              <Chat barsVisible={barsVisible} />
            </Anchor>
          </PresenceScope>
        </QuickHide>
      </PresenceScope>
    </div>
  )
}

/** App.tsx's notices place, wanted off the lobby alone (`hud.paused` only
 *  queues them, in the store). `barsVisible` is today's (App's hudUp). */
export function NoticesLayer({ want, barsVisible }: { want: boolean; barsVisible: boolean }) {
  const held = useCurtainCovered()
  const paused = usePauseOpen()
  return (
    <div className="bc-kit hud-v2" {...(held || paused ? { [AWAY_ATTR]: 'hud-notices' } : {})}>
      <PresenceScope hold={held} preset={PRESET}>
        <QuickHide hidden={paused}>
          <PresenceScope want={want}>
            <ScopeFloor order={LAST_TURN} />
            <Anchor id="notices">
              <Notices barsVisible={barsVisible} />
            </Anchor>
          </PresenceScope>
        </QuickHide>
      </PresenceScope>
    </div>
  )
}
