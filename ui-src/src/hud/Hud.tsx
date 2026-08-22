import {
  useUi, selHud, selStorm, selSquad, selFeed, selDbno, selMatch, selInv,
  selVehicle,
} from '../store'
import { useScreenMetrics } from './useScreenMetrics'
import Vitals from './Vitals'
import VehicleBars from './VehicleBars'
import StormBar from './StormBar'
import WarmupTimer from './WarmupTimer'
import Counters from './Counters'
import KillFeed from './KillFeed'
import SquadPanel from './SquadPanel'
import DbnoOverlay from './DbnoOverlay'
import InventoryBar from './InventoryBar'
import SpectateHint from './SpectateHint'
import HitFeedback from './HitFeedback'
import TalkingBar from './TalkingBar'
import VoiceNotice from './VoiceNotice'

/**
 * WHERE THE SQUAD PANEL ENDS, for anything that has to sit below it.
 *
 * Exported as an id rather than a rem constant because the panel's height is
 * data: solo renders nothing at all, a squad renders up to four plates, and a
 * plate loses its two bars the moment that player is out. Anything that reasons
 * about the free space in the left column has to measure the box, and this is
 * the handle it measures. screens/PlayerList.tsx is the only caller today.
 */
export const SQUAD_SLOT_ID = 'br-squad-slot'

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
  // A SNIPER SCOPE IS A FULL-SCREEN SCALEFORM and our panels sit on top of it.
  // Only scoped weapons do this -- aiming a pistol draws no overlay, so the
  // HUD stays up for it (user, 2026-08-07).
  const scoped = useUi((s) => s.scoped)
  const hud   = useUi(selHud)
  const storm = useUi(selStorm)
  const squad = useUi(selSquad)
  const talking = useUi((s) => s.talking)
  // TWO PRIMITIVES RATHER THAN THE ENVELOPE, on purpose. Selecting `s.voice`
  // would re-render this component -- the whole HUD -- on every push that
  // changes the talking list, which is several times a second while anybody is
  // speaking. These two move when the player's voice VERDICT moves, which is
  // roughly once a match.
  const voiceSilent = useUi((s) => s.voice.silent === true)
  const voiceChosen = useUi((s) => s.voice.chosen === true)
  const feed  = useUi(selFeed)
  const dbno  = useUi(selDbno)
  const match = useUi(selMatch)
  const inv   = useUi(selInv)
  // The car under this player, in any seat. Null on foot.
  const vehicle = useUi(selVehicle)

  // Applies the game's resolution and safe zone to CSS variables.
  useScreenMetrics()

  // Red only when the storm is actually hurting: dps is 0 during the phase-1
  // free-loot hold, where being outside circle 1 is a rotation problem, not
  // an emergency.
  const outside = (storm?.edgeDistance ?? -1) > 0 && (storm?.dps ?? 0) > 0

  // STILL IN THE AIR -- and "in the air" is now two facts, not one.
  //
  // The squad panel and the inventory bar hide during the descent, because the
  // game's own help boxes own those corners until touchdown. The test was the
  // server's state alone, and the server only says 'alive' once the landing
  // report has completed its round trip -- a message with its own retry loop
  // and its own server-side rescue net, because it goes missing. Every
  // millisecond it is late is a player standing in a POI with no inventory bar
  // and no squad panel; in the bad case it lasted until the match itself
  // reached 'playing' (#126).
  //
  // `hud.landed` is this player's own ped reporting that it is on the ground.
  // It cannot be observed for anyone else and is not used for anything but
  // deciding what to draw -- see the note on HudPayload.landed.
  const descending =
    (hud.state === 'freefall' || hud.state === 'glide') && !hud.landed

  return (
    <div
      className="hud-layer fixed inset-0 transition-opacity duration-200"
      style={{ opacity: (visible && !scoped) ? 1 : 0 }}
      aria-hidden={!visible || scoped}
    >
      {/* Storm vignette is full-bleed: it should ignore the safe zone, because
          it is an effect rather than an element to read. Always mounted so the
          5s opacity transition can play both directions -- in step with the
          client-side weather blend. */}
      <div className="storm-vignette" style={{ opacity: outside ? 1 : 0 }} />

      {/* Outside .hud-safe on purpose: the marker is dead screen-centre and
          the banner is centre-lower. Neither belongs inside a box that is
          inset by the safe zone -- the crosshair is not safe-zone relative. */}
      <HitFeedback />

      <div className="hud-safe">
        {/* Top row */}
        {/* Top centre carries whichever clock matters right now. Warmup owns it
            until the drop; the storm owns it for the rest of the match. They
            never overlap, so they share the slot rather than competing. */}
        <div className="absolute left-1/2 -translate-x-1/2" style={{ top: 'var(--safe-y)' }}>
          <WarmupTimer />
          <StormBar storm={storm} />
        </div>

        {/* Top row: counters right, squad left, BOTH on --hud-top so they sit
            at the same height and both clear the engine's help band. */}
        <div className="absolute" style={{ top: 'var(--hud-top)', right: 'var(--safe-x)' }}>
          <Counters
            alive={hud.alive}
            squads={hud.squadsAlive}
            kills={hud.kills}
            mode={match.mode}
            // SUMMED HERE, not sent as a field. Every squadmate's own count is
            // already on the wire for the squad panel, so a separate total
            // would be a second source for the same fact -- and the two would
            // disagree the moment one of them lagged a push.
            squadKills={squad.members.length > 1
              ? squad.members.reduce((n, m) => n + (m.kills ?? 0), 0)
              : undefined}
          />
        </div>

        <div
          className="absolute w-[16rem]"
          style={{ top: 'calc(var(--hud-top) + 5rem)', right: 'var(--safe-x)' }}
        >
          <KillFeed entries={feed} />
        </div>

        {/* Left column, top to bottom: squad, chat (rendered separately), radar.
            Each has its own band so none can grow into another -- the squad
            panel varies with squad size and chat with message count.

            Hidden until the player has LANDED: the game's native help boxes
            ("Press SPACE to open the glider.") draw in exactly this corner,
            and the squad panel sat on top of them (user report, 2026-08-04).
            The bus ride already hides the whole HUD; this covers the descent. */}
        {/* THE ID IS NOT DECORATION. screens/PlayerList.tsx measures this slot
            to find out where the left column is free -- the squad panel is the
            one thing in that column whose height is genuinely unknowable in
            advance (0 rows solo, up to 4 in squads, and a row loses its bars
            when its player dies), so the panel that has to sit under it reads
            the rendered box rather than guessing at a rem constant. Removing or
            renaming this leaves that panel falling back to the safe zone and
            overlapping this one again. */}
        {!descending && (
          <div
            id={SQUAD_SLOT_ID}
            className="absolute w-[13rem]"
            style={{ top: 'var(--hud-top)', left: 'var(--safe-x)' }}
          >
            <SquadPanel
              squad={squad}
              talking={talking}
              voiceSilent={voiceSilent}
              voiceChosen={voiceChosen}
            />
          </div>
        )}

        {/* Vitals sit UNDER the radar, spanning its width -- not over it.
            Positioned FIXED against the viewport (not inside hud-safe's
            padding) because the --map-* variables are viewport-true
            coordinates of the real radar.

            THE OFFSET IS NEGATIVE NOW. It was `+ 0.3rem`, which tucked a
            0.75rem strip just inside the radar's lower edge. Making the
            numerals legible meant growing the bar, and a taller bar anchored
            at its BOTTOM grows upward -- so it climbed over the minimap
            (user, 2026-08-09). Dropping the anchor below the radar's bottom
            edge puts the whole strip back underneath it.

            --vitals-drop is one number on purpose: the exact clearance is a
            thing only an eye in game can settle, and this is the knob. */}
        <div
          className="fixed"
          style={{
            left: 'var(--map-left)',
            bottom: 'calc(var(--map-bottom) - var(--vitals-drop))',
            width: 'var(--map-w)',
          }}
        >
          <Vitals hp={hud.hp} armour={hud.armour} stamina={hud.stamina} />
        </div>

        {/* Bottom right, clear of the radar on the left and of the kill feed
            above it. Hidden during the descent for the same reason the squad
            panel is: the game's own help boxes own the screen until touchdown,
            and there is nothing in the bar to look at before you land. */}
        {!descending && (
          <div
            className="absolute flex flex-col items-end gap-1"
            style={{ bottom: 'var(--safe-y)', right: 'var(--safe-x)' }}
          >
            {/* ═══ THE CAR YOU ARE IN, ABOVE THE INVENTORY AND IN THE SAME
                    COLUMN ═══

                IN THE FLEX-COL, NOT FLOATING OVER IT, and that is the whole
                reason this div grew a layout. The inventory bar's height is
                DATA -- the ammo panel exists only for a weapon with a clip --
                so anything anchored above it by arithmetic would jump every
                time the player selected a bandage. Stacking means the browser
                measures.

                THE COLUMN GROWS UPWARD from the bottom safe edge, which is free
                here in a way it is not on the left: the kill feed is the only
                thing above, and it hangs off --hud-top + 5rem at the TOP of the
                screen. At 1280x720 the strip adds about 17px to a column whose
                top edge sits around y=600; the feed's lowest row is up near
                y=190 with eight entries. They do not meet.

                RENDERS null WHEN THERE IS NO VEHICLE, so the column is exactly
                what it was before for a player on foot -- see VehicleBars. */}
            <VehicleBars vehicle={vehicle} />
            <InventoryBar inv={inv} />
          </div>
        )}


        {/* Bottom centre: who is speaking. Deliberately NOT hidden during the
            descent -- the corners that hide are the ones the game's own help
            boxes take over, and this is not one of them. Squad comms during
            the drop is exactly when knowing who is talking matters. */}
        <TalkingBar />

        {/* ═══ AND, ABOVE IT, THE TWO SURFACES THAT SHARE THAT EDGE ═══

            ONE COLUMN, NOT TWO ANCHORS. VoiceNotice used to position itself at
            `--safe-y + 1.6rem` -- one hand-measured talking line up -- and the
            spectate hint would have needed the same arithmetic plus VoiceNotice's
            own height to sit clear of both. Two components each computing where
            the other one is is how they end up drawn on top of each other, and
            it is exactly what the owner asked this hint not to do ("not
            overlapping with our 'Currently talking' text").

            SO THE COLUMN OWNS THE CLEARANCE and the children own nothing but
            their content. --talkline-h is derived from the same font size
            TalkingBar reads, so it grows with the player's text-size preference
            and this stack rises with it.

            THE CLEARANCE DOES NOT COLLAPSE when nobody is speaking, even though
            TalkingBar renders nothing then. A stack that dropped a line every
            time the room went quiet would move a hint while it was being read.

            ORDER IS BOTTOM-UP BY URGENCY: the spectate hint sits closest to the
            bottom edge because it is the one the owner asked to be at the
            bottom centre, and the voice headline -- which changes only when a
            squad does -- floats above it. */}
        <div
          className="absolute left-1/2 -translate-x-1/2 flex flex-col
                     items-center gap-1 pointer-events-none"
          style={{
            bottom: 'calc(var(--safe-y) + var(--talkline-h) + 0.4rem)',
          }}
        >
          {/* WHY YOU MIGHT BE HEARING NONE OF THEM. Renders nothing on nearby,
              which is almost always -- see VoiceNotice. */}
          <VoiceNotice />
          {/* Who you are watching and which keys move you on. Renders nothing
              unless a session is running. */}
          <SpectateHint />
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
