import { useEffect, useLayoutEffect, useRef, useState } from 'react'
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
 * Below the radar, or above it -- decided from the safe zone the game actually
 * reports, re-decided whenever it moves.
 *
 * ═══ THE RULE ═══
 *
 *   "if the safezone size doesn't allow our health/shield bars to be displayed
 *    below the minimap (because they'd get cut off) then we should display them
 *    on top of the minimap instead and bump the chat up"   -- owner, 2026-08-23
 *
 * ═══ WHY IT CANNOT BE ANSWERED FROM THE ASPECT RATIO ═══
 *
 * The radar is anchored to the safe zone's BOTTOM-left corner, so the strip's
 * usual place -- --vitals-drop below the radar's lower edge -- is not inside
 * the safe zone at all. It is in the margin underneath it. That margin is
 * whatever the player's safe-zone slider left there, and at the top of the
 * slider's range there is none: the bars run off the bottom of the screen.
 *
 * That happens on a 16:9 monitor. It is not an ultrawide symptom and a test
 * that keyed on the aspect ratio would miss it entirely -- which is the whole
 * reason #231 says this must be MEASURED.
 *
 * ═══ WHAT IS MEASURED, AND WHY IT IS MEASURED THIS WAY ═══
 *
 * Two zero-width hidden probes, sized in the same CSS variables the layout is
 * written in, and read back in pixels:
 *
 *   space  height: var(--map-bottom)   the margin below the radar
 *   drop   height: var(--vitals-drop)  how much of it the strip needs
 *
 * Reading a probe rather than doing the arithmetic in TypeScript is what keeps
 * this honest. Nothing here knows that --vitals-drop is 0.85rem, that a rem is
 * 1.481vh, that the root font size is clamped at both ends, or that the
 * interface-size slider multiplies it -- change any of those, in any unit, and
 * the measurement follows. A hardcoded rem would be a second copy of a number
 * that is already declared once, and it would be the copy that is wrong.
 *
 * ═══ RE-DECIDED, NOT DECIDED ONCE ═══
 *
 * The read runs after EVERY render of the HUD, and the HUD re-renders whenever
 * a screen envelope lands (useScreenMetrics holds the metrics in state). Lua
 * republishes the rectangle the moment the safe zone moves, so a player
 * dragging that slider mid-match watches the strip change places -- which is
 * the requirement, and it is the failure mode a decide-once version would ship
 * with looking perfectly correct on the developer's machine.
 *
 * DELIBERATELY NOT A ResizeObserver, which is the obvious tool. Its callbacks
 * ride the rendering lifecycle, so they arrive only while frames are being
 * produced -- and in the headless browser this was verified in, which composites
 * nothing, it did not fire once: not for the probes, and not for a plain visible
 * div whose height was being changed underneath it. That is a property of that
 * browser rather than of CEF, and it is exactly the point: a measurement that
 * cannot be exercised where the work is done is a measurement nobody can check.
 * The render lifecycle can be, and setFit is guarded, so a re-read that finds
 * nothing new costs one comparison and no render.
 *
 * The window listener is for the harness, where the viewport can change without
 * any envelope arriving. In game a resolution change republishes the rectangle,
 * so that path is already covered.
 *
 * The strip's own height is measured too, and only for the chat column: it is
 * published as --vitals-lift so chat can move up by exactly the space the strip
 * took, which is the "bump the chat up" half of the rule.
 */
function useVitalsPlacement() {
  const stripRef = useRef<HTMLDivElement>(null)
  const spaceRef = useRef<HTMLDivElement>(null)
  const dropRef = useRef<HTMLDivElement>(null)
  // `below` starts true, which is where the strip has always been: until the
  // probes have been read once, nothing moves.
  const [fit, setFit] = useState({ below: true, strip: 0 })
  // Bumped by a viewport change, purely to force the read below to run again.
  const [, setTick] = useState(0)

  // NO DEPENDENCY ARRAY: this is a measurement of what was just laid out, so it
  // belongs after every layout. The guard inside setFit is what stops it from
  // being a render loop -- an unchanged answer returns the same state object.
  useLayoutEffect(() => {
    const strip = stripRef.current
    const space = spaceRef.current
    const drop = dropRef.current
    if (!strip || !space || !drop) return

    const spacePx = space.getBoundingClientRect().height
    const dropPx = drop.getBoundingClientRect().height
    // ROUNDED, AND THAT IS THE LOOP GUARD. This effect runs after every layout
    // and writes state, so the comparison below is the only thing between it
    // and an infinite render -- and a raw sub-pixel height that flickered in
    // its last decimal place would defeat it silently.
    const stripPx = Math.round(strip.getBoundingClientRect().height * 100) / 100
    // FITS ⟺ THE STRIP'S LOWER EDGE IS STILL ON THE SCREEN. The strip is
    // bottom-anchored, so its lower edge IS the anchor: --map-bottom minus
    // --vitals-drop, measured up from the bottom of the viewport.
    const below = spacePx >= dropPx
    setFit((p) => (p.below === below && p.strip === stripPx
      ? p
      : { below, strip: stripPx }))
  })

  useEffect(() => {
    const bump = () => setTick((n) => n + 1)
    window.addEventListener('resize', bump)
    return () => window.removeEventListener('resize', bump)
  }, [])

  // Published for the chat column, which has no other way to know. `calc` with
  // the gap left symbolic so the two surfaces cannot drift apart.
  useLayoutEffect(() => {
    document.documentElement.style.setProperty(
      '--vitals-lift',
      fit.below ? '0px' : `calc(${fit.strip}px + var(--vitals-gap))`,
    )
  }, [fit.below, fit.strip])

  return { fit, stripRef, spaceRef, dropRef }
}

/**
 * The in-match HUD.
 *
 * LAYOUT MODEL
 *
 * Everything lives inside `.hud-safe`, a full-viewport box padded by the game's
 * real safe zone. Positions inside it are anchored to its edges; sizes are in
 * rem, and rem is tied to viewport height (see index.css). The result scales
 * linearly across 720p to 4K from a single number, and lands where the player
 * expects on any aspect ratio the engine reports.
 *
 * FOUR EDGES, NOT TWO: --safe-x/--safe-y are the left and top insets and
 * --safe-r/--safe-b the right and bottom, because they are not the same number
 * once the display stops being 16:9. And `.hud-safe` is NOT transformed -- it
 * used to be, for an ultrawide clamp, and that quietly captured every
 * `position: fixed` child inside it (#231; see index.css and check-ui R12).
 *
 * The bottom-left corner is reserved for GTA's native radar, which we
 * deliberately do not replace -- re-rendering the map in CEF costs real frames
 * and the storm circle already comes free from AddBlipForRadius. Its rectangle
 * comes from Lua as --map-left / --map-bottom / --map-w / --map-h, in viewport
 * units, and every surface that anchors to the radar reads those same four.
 *
 * ═══ THE MINIMAP IS THE ORIGIN, AND THE VIEWPORT IS NOT ═══
 *
 * ...and THAT is the layout model, restated after the first ultrawide fix got
 * it half right. GTA lays its own interface out inside a 16:9 box centred in
 * the viewport and will not move the minimap out of it, while the safe zone
 * correctly follows the panel (citizenfx/fivem#2719 says both). One rectangle
 * at 16:9; two rectangles a quarter of a screen apart at 32:9.
 *
 * So the HUD's left and right edges are --hud-left and --hud-right, the edges
 * of the box the MAP is in. Every surface that reads as part of the cluster
 * around the map uses them: the squad panel, the counters, the kill feed, the
 * inventory column -- alongside the vitals strip, the chat column and the
 * notice stack, which already read --map-* directly. --safe-x and --safe-r are
 * the PANEL's edges and no HUD surface wants them; check-ui R13 says so.
 *
 * WHAT STAYS ON THE VIEWPORT, and why it is not an oversight:
 *
 *   the storm bar and warmup timer   top centre
 *   the talking line, voice notice
 *     and spectate hint              bottom centre
 *   the DBNO plate                   bottom centre
 *   the hit marker                   dead screen centre, outside .hud-safe
 *   the storm vignette               full bleed, an effect and not an element
 *
 * A CENTRED THING IS ALREADY CORRECT, because the engine's box is itself
 * centred: the middle of the frame and the middle of the viewport are the same
 * column at every aspect ratio. Moving them would be motion with no meaning.
 * The vignette and the hit marker are about the SCREEN -- a crosshair that
 * drifted off the point of aim to keep the minimap company would be a bug.
 *
 * Vertically nothing changes anywhere: a panel wider than 16:9 has spare
 * WIDTH, so --safe-y and --safe-b are still the engine's own top and bottom.
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
  // ═══ THE VOLTS READOUT, AND WHY IT IS A NUMBER-OR-NULL RATHER THAN TWO
  //     PROPS ═══
  //
  // Owner, 2026-08-29: "when a DUI is shown at the shop, please show their
  // current volts balance with NUI where the bullet rounds show."
  //
  // "While a plate is up, and only then" is one condition and one value, so it
  // is resolved to one thing HERE rather than passed down as a flag plus a
  // balance for InventoryBar to recombine. A component given both would be
  // free to render a balance with the flag false, and that is the bug this
  // shape cannot have.
  //
  // THE FIGURE IS THE STORE'S OWN. `market.balance` is what the Store screen
  // renders and it is refreshed on every MARKET_STATE, so the HUD and the shop
  // screen cannot disagree about how many Volts somebody has.
  const shopVolts = useUi((s) => (s.shopPlate ? s.market.balance : null))
  // THE CURRENCY'S NAME, FROM THE ONE PLACE IT IS WRITTEN. Lua sends it with
  // the market state (BR.Config.Market.currency) so the word lives in config
  // rather than in two languages; the Store screen reads the same field. A
  // SEPARATE primitive selector rather than one object with the balance, for
  // the reason stated two blocks up about `voice`: a fresh object every render
  // re-renders the whole HUD.
  const currency = useUi((s) => s.market.currency ?? 'Volts')

  // Applies the game's resolution and safe zone to CSS variables.
  useScreenMetrics()

  // Below the radar or above it, re-decided from the real safe zone.
  const { fit: { below }, stripRef, spaceRef, dropRef } = useVitalsPlacement()

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
            at the same height and both clear the engine's help band.

            RIGHT IS --hud-right, NOT --safe-r. See the note on the squad panel
            below: the two are the same edge at 16:9 and a quarter of the screen
            apart at 32:9, and this corner is part of the cluster the owner
            asked to keep with the map. */}
        <div className="absolute" style={{ top: 'var(--hud-top)', right: 'var(--hud-right)' }}>
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
          style={{ top: 'calc(var(--hud-top) + 5rem)', right: 'var(--hud-right)' }}
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
            /* LEFT IS --hud-left, WHICH IS THE MINIMAP'S EDGE, NOT --safe-x.
               The squad panel heads a column whose other two members -- chat
               and the vitals strip -- have always anchored to the map, and on
               an ultrawide --safe-x is a different edge entirely: the engine
               keeps the map inside a centred 16:9 box while the safe zone
               follows the panel (citizenfx/fivem#2719). This panel sat on the
               far left of a 32:9 screen with the map a quarter of a screen
               away from it, which is the owner's screenshot. Identical to
               --safe-x on 16:9. */
            style={{ top: 'var(--hud-top)', left: 'var(--hud-left)' }}
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

            FIXED, AND IT NOW ACTUALLY IS. The comment here used to claim this
            was "positioned FIXED against the viewport (not inside hud-safe's
            padding) because the --map-* variables are viewport-true
            coordinates of the real radar". The reason was right and the claim
            was false: `.hud-safe` carried `transform: translateX(-50%)` for the
            ultrawide clamp, a transformed ancestor becomes the containing block
            for `position: fixed` descendants, and this strip resolved against
            THAT box instead of the viewport -- 305px away from the minimap at
            32:9, while the notice stack, `fixed` at App level and outside the
            box, stayed put. index.css carries the write-up; check-ui R12 fails
            the build if the transform comes back. The word `fixed` below is
            load-bearing and so is where this div is mounted.

            THE OFFSET IS NEGATIVE. It was `+ 0.3rem`, which tucked a 0.75rem
            strip just inside the radar's lower edge. Making the numerals
            legible meant growing the bar, and a taller bar anchored at its
            BOTTOM grows upward -- so it climbed over the minimap (user,
            2026-08-09). Dropping the anchor below the radar's bottom edge puts
            the whole strip back underneath it.

            --vitals-drop is one number on purpose: the exact clearance is a
            thing only an eye in game can settle, and this is the knob.

            AND WHEN THERE IS NO ROOM DOWN THERE, THE STRIP GOES ABOVE THE
            RADAR INSTEAD -- see useVitalsPlacement. The fallback anchors to the
            radar's TOP edge, which is --map-h above its bottom one, and cannot
            run off anything: it is only ever reached when the bottom margin is
            nearly zero, and it grows into the middle of the screen. */}
        <div
          ref={stripRef}
          className="fixed"
          style={{
            left: 'var(--map-left)',
            bottom: below
              ? 'calc(var(--map-bottom) - var(--vitals-drop))'
              : 'calc(var(--map-bottom) + var(--map-h) + var(--vitals-gap))',
            width: 'var(--map-w)',
          }}
        >
          {/* THE TWO PROBES. Zero width, hidden, out of flow: they change
              nothing about the layout and exist only to resolve two CSS
              lengths into pixels so the placement above can compare them.
              See useVitalsPlacement for why this is measured rather than
              computed. */}
          <div
            ref={spaceRef}
            className="absolute bottom-0 left-0 w-0 pointer-events-none"
            style={{ height: 'var(--map-bottom)', visibility: 'hidden' }}
            aria-hidden
          />
          <div
            ref={dropRef}
            className="absolute bottom-0 left-0 w-0 pointer-events-none"
            style={{ height: 'var(--vitals-drop)', visibility: 'hidden' }}
            aria-hidden
          />
          <Vitals hp={hud.hp} armour={hud.armour} stamina={hud.stamina} />
        </div>

        {/* Bottom right, clear of the radar on the left and of the kill feed
            above it. Hidden during the descent for the same reason the squad
            panel is: the game's own help boxes own the screen until touchdown,
            and there is nothing in the bar to look at before you land. */}
        {!descending && (
          <div
            className="absolute flex flex-col items-end gap-1"
            /* RIGHT IS --hud-right. "this should include our ... inventory"
               (owner, 2026-08-23): on the 32:9 screenshot this column was hard
               against the viewport's right edge while the map sat near the
               middle. BOTTOM is still --safe-b, and deliberately: a panel wider
               than 16:9 has spare WIDTH, so the bottom edge of the engine's
               layout box IS the safe zone's and there is nothing to correct. */
            style={{ bottom: 'var(--safe-b)', right: 'var(--hud-right)' }}
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
            <InventoryBar inv={inv} volts={shopVolts} currency={currency} />
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
            bottom: 'calc(var(--safe-b) + var(--talkline-h) + 0.4rem)',
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
            the first version of this HUD ended up drawn on top of the map.

            NOTE THIS IS THE *NUI DEV BUILD*, `npm run dev` -- not /brdebug,
            which has never drawn it. screen.lua used to say otherwise.

            IT READS THE SAME RECTANGLE EVERYTHING ELSE DOES. It used to be
            drawn from --radar-w/--radar-h, a second copy of this rectangle in
            rem, so the outline could agree with itself while disagreeing with
            every surface it exists to check against. `fixed`, for the same
            reason the vitals strip is: --map-* are viewport-true. */}
        {import.meta.env.DEV && (
          <div
            className="fixed border border-dashed border-white/20 rounded-md
                       flex items-end justify-center pb-1"
            style={{
              left: 'var(--map-left)',
              bottom: 'var(--map-bottom)',
              width: 'var(--map-w)',
              height: 'var(--map-h)',
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
