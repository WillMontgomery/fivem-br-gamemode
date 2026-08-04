import { useUi, selHud, selStorm, selSquad, selFeed, selDbno } from '../store'
import { useScreenMetrics } from './useScreenMetrics'
import Vitals from './Vitals'
import StormBar from './StormBar'
import WarmupTimer from './WarmupTimer'
import Counters from './Counters'
import KillFeed from './KillFeed'
import SquadPanel from './SquadPanel'
import DbnoOverlay from './DbnoOverlay'

/**
 * The in-match HUD.
 *
 * LAYOUT MODEL
 *
 * Everything lives inside `.hud-safe`, a box inset by the game's real safe zone
 * and clamped on very wide displays. Positions inside it are anchored to its
 * edges; sizes are in rem, and rem is tied to viewport height (see index.css).
 * The result scales linearly across 720p to 4K from a single number, and lands
 * where the player expects on any aspect ratio the engine reports.
 *
 * The bottom-left corner is reserved for GTA's native radar, which we
 * deliberately do not replace -- re-rendering the map in CEF costs real frames
 * and the storm circle already comes free from AddBlipForRadius. Its footprint
 * comes from Lua as --radar-w / --radar-h.
 *
 * Deliberately plain Tailwind rather than HeroUI: these are read-only readouts
 * on the 60fps path, not controls. HeroUI earns its place in the lobby and
 * summary screens.
 */
export default function Hud({ visible }: { visible: boolean }) {
  const hud   = useUi(selHud)
  const storm = useUi(selStorm)
  const squad = useUi(selSquad)
  const feed  = useUi(selFeed)
  const dbno  = useUi(selDbno)

  // Applies the game's resolution and safe zone to CSS variables.
  useScreenMetrics()

  // Red only when the storm is actually hurting: dps is 0 during the phase-1
  // free-loot hold, where being outside circle 1 is a rotation problem, not
  // an emergency.
  const outside = (storm?.edgeDistance ?? -1) > 0 && (storm?.dps ?? 0) > 0

  return (
    <div
      className="hud-layer fixed inset-0 transition-opacity duration-200"
      style={{ opacity: visible ? 1 : 0 }}
      aria-hidden={!visible}
    >
      {/* Storm vignette is full-bleed: it should ignore the safe zone, because
          it is an effect rather than an element to read. */}
      {outside && <div className="storm-vignette" />}

      <div className="hud-safe">
        {/* Top row */}
        {/* Top centre carries whichever clock matters right now. Warmup owns it
            until the drop; the storm owns it for the rest of the match. They
            never overlap, so they share the slot rather than competing. */}
        <div className="absolute left-1/2 -translate-x-1/2" style={{ top: 'var(--safe-y)' }}>
          <WarmupTimer />
          <StormBar storm={storm} />
        </div>

        <div className="absolute" style={{ top: 'var(--safe-y)', right: 'var(--safe-x)' }}>
          <Counters alive={hud.alive} squads={hud.squadsAlive} kills={hud.kills} />
        </div>

        <div
          className="absolute w-[16rem]"
          style={{ top: 'calc(var(--safe-y) + 5rem)', right: 'var(--safe-x)' }}
        >
          <KillFeed entries={feed} />
        </div>

        {/* Left column, top to bottom: squad, chat (rendered separately), radar.
            Each has its own band so none can grow into another -- the squad
            panel varies with squad size and chat with message count. */}
        <div
          className="absolute w-[13rem]"
          style={{ top: 'var(--safe-y)', left: 'var(--safe-x)' }}
        >
          <SquadPanel squad={squad} />
        </div>

        {/* Vitals sit exactly where GTA's own minimap strip was: overlapping
            the radar's lower edge, spanning its width. Positioned FIXED
            against the viewport (not inside hud-safe's padding) because the
            --map-* variables are viewport-true coordinates of the real radar. */}
        <div
          className="fixed"
          style={{
            left: 'var(--map-left)',
            bottom: 'calc(var(--map-bottom) + 0.3rem)',
            width: 'var(--map-w)',
          }}
        >
          <Vitals hp={hud.hp} armour={hud.armour} />
        </div>

        {dbno.downed && <DbnoOverlay dbno={dbno} />}

        {/* Dev-only outline of the native radar's footprint. Without it this
            collision is invisible until you are in-game, which is exactly how
            the first version of this HUD ended up drawn on top of the map. */}
        {import.meta.env.DEV && (
          <div
            className="absolute border border-dashed border-white/20 rounded-md
                       flex items-end justify-center pb-1"
            style={{
              left: 'var(--safe-x)',
              bottom: 'var(--safe-y)',
              width: 'var(--radar-w)',
              height: 'var(--radar-h)',
            }}
          >
            <span className="text-[0.55rem] uppercase tracking-widest text-white/25">
              native radar
            </span>
          </div>
        )}
      </div>
    </div>
  )
}
