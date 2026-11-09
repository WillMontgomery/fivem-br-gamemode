import { useRef } from 'react'
import { PresenceScope, QuickHide, usePresence, Vitals, VITALS_H, u } from '../../ui/broadcast'
import {
  useUi, selHud, selStorm, selHudSquad, selFeed, selDbno, selMatch, selInv, selVehicle,
} from '../../store'
import { AWAY_ATTR } from '../../tutorial/progress'
import { useFade } from '../../ui/useFade'
import { SQUAD_SLOT_ID } from '../Hud'
import { useScreenMetrics } from '../useScreenMetrics'
import { useVitalsPlacement } from '../useVitalsPlacement'
import { useHudConditions } from '../useHudConditions'
import VehicleBars from '../VehicleBars'
import StormBar from '../StormBar'
import WarmupTimer from '../WarmupTimer'
import Counters from '../Counters'
import KillFeed from '../KillFeed'
import SquadPanelV2, { hasSquad } from '../SquadPanelV2'
import DbnoOverlay from '../DbnoOverlay'
import InventoryBar from '../InventoryBar'
import SpectateHint from '../SpectateHint'
import HitFeedback from '../HitFeedback'
import { TalkingBox, TalkingRow } from '../TalkingBar'
import VoiceNotice from '../VoiceNotice'
import { YubikeyIcon } from '../YubikeyIcon'
import { Anchor, ScopeFloor } from './Anchor'
import { LAST_TURN } from './choreo'

/**
 * UI V2'S HUD (#431, #436): today's HUD, element for element and class for
 * class (../Hud.tsx), with EVERY element inside a kit presence (./Anchor.tsx)
 * at its corner and its turn of the Broadcast wipe (./choreo.ts). The owner
 * picked it on the preview stage; this is that stage's HUD without the
 * harness. What differs from Hud.tsx is marked V2.
 *
 * V2 1, THE REASONS IT HIDES, which the kit treats differently:
 *   the HUD going away   (lobby, bus, ambulance, teardown)  -> the scope's want
 *                         goes false and every anchor plays its way out
 *                         (./HudLayer.tsx)
 *   the curtain          -> the scope's hold: hidden while the curtain is
 *                         covered, then the reveal as it starts to lift
 *   GTA's map and menus  -> App's ui gate, as today, round everything
 *   our pause menu       -> a quick hide round the HUD, chat and notices
 *   a scope              -> the quick hide HERE, round the HUD alone
 *
 * V2 2, THE ROOT'S OPACITY. data-layer="hud" keeps its opacity, useFade('hud')
 * and layer-off (the F8 screen report, #252), but it is no longer the hide: it
 * is up from the first frame of a reveal until the LAST anchor has left (a
 * sentinel presence at turn 0 leaves last: the leave runs the turns
 * backwards), so a slow hide is the anchors' way out, never cut short by the
 * root, and the root snaps.
 *
 * V2 3, THE GATES. The squad slot keeps its `descending` mount (that pop is
 * never seen: it comes with the HUD arriving at the jump), and its gun-shop
 * condition becomes a scope round the slot, so the panel leaves and comes back.
 * The warmup card, the talking line and the spectate hint are drawn on today's
 * conditions, the one copy both HUDs call (../useHudConditions.ts), and their
 * anchors hold what they last drew through the way out.
 *
 * V2 4, THE WALKTHROUGH. A held or quick-hidden presence is visibility:
 * hidden, and the in-game walkthrough ends a run whose target it cannot see
 * (TutorialLayer.tsx). Today's HUD hides by opacity alone, so its targets stay
 * visible under the curtain, a scope and our pause menu. So while this one is
 * held or quick-hidden its root says its targets are away (AWAY_ATTR), and a
 * card waits for them instead of ending the run.
 *
 * V2 5, THE SLANTED VITALS (the owner's pick, 2026-11-03: slanted, like
 * Broadcast, not today's pills). The strip draws the kit's Vitals, fed hud.hp
 * and hud.armour as today, in the same measured strip, at the same anchor and
 * turn. They are VITALS_H kit units tall, three times today's 1.05rem row, so
 * the strip hangs by its own height (--vitals-drop = VITALS_H, on this strip
 * alone): the one placement both HUDs call then puts it under the radar only
 * where the margin holds all of it, and above the radar with the chat moved up
 * everywhere else -- never over the radar. At the usual safe zones that is
 * above, as in every clip the owner saw; at a safe zone of 0.9 it is under the
 * radar from 1080p up at the default Interface size (check-layout's hud/v2 and
 * hud/v2-safe-low hold both sides).
 *
 * V2 6, THE BROADCAST SQUAD PANEL (the owner's pick for #429). The slot draws
 * ../SquadPanelV2.tsx, today's props off today's selectors, where today's HUD
 * draws ../SquadPanel.tsx. Each of its rows is a kit presence of its own, so
 * the slot's anchor stands down once it sees them (./Anchor.tsx, `ownable`)
 * and moves nothing: the rows go on air top mate first and off air bottom
 * mate first, the panel's own way, at the gun-shop counter and with the whole
 * HUD alike, as on the preview stage. Left standing, the anchor's content
 * channel would fade the whole panel in one 140 ms go and cut every row short
 * (check-layout's hud/v2-squad-out holds it).
 */

/** Every walkthrough target this HUD draws (data-tut), its own and those of
 *  the elements in it: the warmup card, the Alive plate, the squad panel, the
 *  inventory bar. */
const HUD_TARGETS = [
  'hud-timer', 'hud-counters', 'hud-alive', 'hud-feed', 'hud-squad', 'squad-name',
  'squad-bars', 'hud-vitals', 'hud-inventory', 'hud-volts', 'hud-minimap',
].join(' ')

export default function HudV2({ rootPreset, paused }: {
  /** The root's timing (choreo.ts ROOT_PRESET, registered by ./HudLayer.tsx). */
  rootPreset: string
  /** Our pause menu is quick-hiding the layer this sits in. */
  paused: boolean
}) {
  // A SNIPER SCOPE IS A FULL-SCREEN SCALEFORM and our panels sit on top of it
  // (Hud.tsx). Here it is a quick hide round the HUD alone.
  const scoped = useUi((s) => s.scoped)
  const hud = useUi(selHud)
  const storm = useUi(selStorm)
  const squad = useUi(selHudSquad)
  const talking = useUi((s) => s.talking)
  // Two primitives rather than the envelope, as in Hud.tsx: they move when the
  // voice verdict does, roughly once a match.
  const voiceSilent = useUi((s) => s.voice.silent === true)
  const voiceChosen = useUi((s) => s.voice.chosen === true)
  const feed = useUi(selFeed)
  const dbno = useUi(selDbno)
  const match = useUi(selMatch)
  const inv = useUi(selInv)
  const vehicle = useUi(selVehicle)
  // The Volts readout and its two conditions, and the squad panel standing
  // down for the shop menu: Hud.tsx's, word for word, with its reasons there.
  const shopVolts = useUi((s) => (
    (s.shopPlate || s.gunshopMenu) ? s.market.balance : null))
  const gunshopMenu = useUi((s) => s.gunshopMenu)
  const currency = useUi((s) => s.market.currency ?? 'Volts')
  // The warmup card, the talking line and the spectate hint: when each is up,
  // and what it shows, from THE ONE COPY both HUDs call (V2 3).
  const cond = useHudConditions()

  // The strip below the radar or above it: THE ONE HOOK both HUDs call, keyed
  // as check-ui R21 reads it.
  const screen = useScreenMetrics()
  const uiScale = useUi((s) => s.settings.uiScale)
  const { fit: { below }, stripRef, spaceRef, dropRef } =
    useVitalsPlacement(screen?.mapBottom, uiScale)

  const outside = (storm?.edgeDistance ?? -1) > 0 && (storm?.dps ?? 0) > 0
  const descending =
    (hud.state === 'freefall' || hud.state === 'glide') && !hud.landed

  // V2 2: THE ROOT IS UP FROM THE REVEAL'S FIRST FRAME TO THE LAST ANCHOR'S
  // LEAVE. A presence in the HUD's scope that moves nothing, timed by its own
  // preset (choreo.ts ROOT_PRESET): up the moment a reveal starts, hidden once
  // the slowest way out can have ended.
  const sentinel = usePresence(true, { order: 0, keepMounted: true, preset: rootPreset })
  const up = sentinel.phase !== 'hidden'
  const rootRef = useRef<HTMLDivElement>(null)
  const settled = useFade('hud', up, 200, rootRef)
  const off = settled && !up
  // V2 4: held under the curtain, or quick-hidden by our pause menu or a scope.
  const away = sentinel.held || paused || scoped

  const yubikey = typeof hud.yubikey === 'string' && hud.yubikey !== ''

  return (
    <div
      ref={rootRef}
      data-layer="hud"
      className={`bc-kit hud-layer fixed inset-0${off ? ' layer-off' : ''}`}
      style={{ opacity: up ? 1 : 0, transition: 'none' }}
      aria-hidden={!up || scoped}
      {...(away ? { [AWAY_ATTR]: HUD_TARGETS } : {})}
    >
      <span
        ref={sentinel.rootProps.ref}
        data-bc-phase={sentinel.rootProps['data-bc-phase']}
        data-bc-preset={sentinel.rootProps['data-bc-preset']}
        className="hud-sentinel"
        style={sentinel.rootProps.style}
        aria-hidden
      />
      <ScopeFloor order={LAST_TURN} />
      <QuickHide hidden={scoped}>
        {/* Hud.tsx: the storm vignette, full bleed, and the hit marker, dead
            screen center. Neither is an anchor: each is an effect with its own
            timing, and they leave with the quick hides around them. */}
        <div className="storm-vignette" style={{ opacity: outside ? 1 : 0 }} />
        <HitFeedback />

        <div className="hud-safe">
          {/* The top-center box is transformed (-translate-x-1/2), so each
              card's anchor goes INSIDE it. */}
          <div className="absolute left-1/2 -translate-x-1/2" style={{ top: 'var(--safe-y)' }}>
            <Anchor id="placard" show={cond.warmup}>
              <WarmupTimer endsAt={match.endsAt} offset={cond.clockOffset} />
            </Anchor>
            <Anchor id="storm" show={storm !== null}>
              <StormBar storm={storm} />
            </Anchor>
          </div>

          <div
            className="absolute flex flex-col items-end gap-2"
            style={{ top: 'var(--hud-top)', right: 'var(--hud-right)' }}
          >
            <Anchor id="counters" keep live={[hud.alive, hud.squadsAlive, hud.kills]}>
              <span data-tut="hud-counters" className="block">
                <Counters
                  alive={hud.alive}
                  squads={hud.squadsAlive}
                  kills={hud.kills}
                  mode={match.mode}
                  squadKills={squad.members.length > 1
                    ? squad.members.reduce((n, m) => n + (m.kills ?? 0), 0)
                    : undefined}
                />
              </span>
            </Anchor>
            <Anchor id="feed" keep>
              <div className="w-[16rem]" data-tut="hud-feed">
                <KillFeed entries={feed} />
              </div>
            </Anchor>
          </div>

          {/* The slot keeps its box and its id (PlayerList measures it). The
              gun-shop menu is a scope round it (V2 3), so the panel takes its
              way out when the menu opens. NO ScopeFloor IN THIS ONE, on
              purpose, as on the preview stage: the slot's scope counts its way
              out from the squad anchor alone, so the menu never waits out the
              HUD's reversed stagger. The Broadcast panel's rows count back in
              the panel's own scope, so on a HUD-wide way out the squad leaves
              with the first anchors, not the last, as the owner saw it. The
              anchor looks for the panel's rows when the panel's own rule
              (hasSquad) moves and as each of its phases begins (V2 6). */}
          {!descending && (
            <div
              id={SQUAD_SLOT_ID}
              className="absolute w-[13rem]"
              style={{ top: 'var(--hud-top)', left: 'var(--hud-left)' }}
            >
              <PresenceScope want={!gunshopMenu}>
                <Anchor id="squad" ownable ownKey={hasSquad(squad)}>
                  <span data-tut="hud-squad" className="block">
                    <SquadPanelV2
                      squad={squad}
                      talking={talking}
                      voiceSilent={voiceSilent}
                      voiceChosen={voiceChosen}
                    />
                  </span>
                </Anchor>
              </PresenceScope>
            </div>
          )}

          {/* The strip is measured (useVitalsPlacement) and fixed on purpose
              (Hud.tsx says why), so the anchor is the span inside it, never
              the strip. It hangs by the slanted vitals' own height (V2 5): its
              bottom and the drop probe both read this --vitals-drop, so "fits
              below" is "the whole strip fits in the margin under the radar". */}
          <div
            ref={stripRef}
            className="fixed"
            style={{
              ['--vitals-drop' as string]: u(VITALS_H),
              left: 'var(--map-left)',
              bottom: below
                ? 'calc(var(--map-bottom) - var(--vitals-drop))'
                : 'calc(var(--map-bottom) + var(--map-h) + var(--vitals-gap))',
              width: 'var(--map-w)',
            }}
          >
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
            {/* The kit's slanted vitals. Their plates carry the kit's own
                channels, so this anchor has no wrapper channel (choreo.ts). */}
            <Anchor id="vitals" keep live={[hud.hp, hud.armour]}>
              <span data-tut="hud-vitals" className="block">
                <Vitals hp={hud.hp} armor={hud.armour} />
              </span>
            </Anchor>
          </div>

          {/* Mounted on landing, like the squad slot: its anchors are late
              joiners and take their turn, or go at once. */}
          {!descending && (
            <div
              className="absolute flex flex-col items-end gap-1"
              style={{ bottom: 'var(--safe-b)', right: 'var(--hud-right)' }}
            >
              <Anchor id="yubikey" show={yubikey}>
                <YubikeyIcon />
              </Anchor>
              <Anchor id="vehicle" show={vehicle !== null}>
                <VehicleBars vehicle={vehicle} />
              </Anchor>
              <Anchor
                id="inventory"
                keep
                live={[shopVolts ?? '', inv.active, ...inv.slots.map((s) => (s ? `${s.id}:${s.count}:${s.clip ?? ''}` : '-'))]}
              >
                <span data-tut="hud-inventory" className="block">
                  <InventoryBar inv={inv} volts={shopVolts} currency={currency} />
                </span>
              </Anchor>
            </div>
          )}

          {/* The talking line's positioned box with the anchor inside it, and
              the row in a box of its own, so the mark and the names stay one
              row however the anchor wraps them. */}
          <TalkingBox>
            <Anchor id="talking" show={cond.talking}>
              <div className="flex items-center gap-2 min-w-0">
                <TalkingRow names={cond.talkingNames} />
              </div>
            </Anchor>
          </TalkingBox>

          <div
            className="absolute left-1/2 -translate-x-1/2 flex flex-col
                       items-center gap-1 pointer-events-none"
            style={{
              bottom: 'calc(var(--safe-b) + var(--talkline-h) + 0.4rem)',
            }}
          >
            <Anchor id="voice">
              <VoiceNotice />
            </Anchor>
            <Anchor id="spectate" show={cond.spectating}>
              <SpectateHint name={cond.spectateName} />
            </Anchor>
          </div>

          {/* DbnoOverlay positions itself (absolute, bottom-40), so its anchor
              is full-stage; its hotDrop stays its entrance, and the anchor
              takes it away with the HUD (the ambulance) or on a revive. */}
          <Anchor id="dbno" show={Boolean(dbno.downed)}>
            <DbnoOverlay dbno={dbno} />
          </Anchor>

          {/* The walkthrough's minimap anchor, an empty box (Hud.tsx). */}
          <div
            data-tut="hud-minimap"
            aria-hidden
            className="fixed pointer-events-none"
            style={{
              left: 'var(--map-left)',
              bottom: 'var(--map-bottom)',
              width: 'var(--map-w)',
              height: 'var(--map-h)',
            }}
          />
          {/* The native radar's footprint, in `npm run dev` alone (Hud.tsx). */}
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
      </QuickHide>
    </div>
  )
}
