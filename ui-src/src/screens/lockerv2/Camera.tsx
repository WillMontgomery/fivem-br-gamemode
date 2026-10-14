import { useRef, type ReactNode } from 'react'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import { play } from '../../audio/cues'
import { CAM } from './copy'
import { SPIN_STEP, SPIN_TICK, SPIN_TICK_MS } from './model'
import { useHold } from './hold'

/**
 * THE CAMERA (owner, 2026-10-13): "what kind of camera controls should we
 * have? let's assume those buttons should be closer on the screen to the ped,
 * in like the half right of center."
 *
 *   THE STAGE    everything right of the panel: a drag turns the look, as
 *                Season 1's does (LOCKER_SPIN), and the mouse wheel zooms.
 *   THE CLUSTER  a small vertical stack of icon plates just right of the
 *                ped, about mid-height: rotate left and right (held, they
 *                keep turning), turn around, zoom in, zoom out, reset view.
 *
 * Turning is LOCKER_SPIN, which Lua already has. Turn around, zoom and reset
 * are LOCKER2_CAM, new: in the browser preview the harness only logs them,
 * and the wiring round moves client/lobbycam.lua's camera for them.
 *
 * OUTSIDE THE ISLAND, so in rem like the rest of the interface: the plates are
 * the lobby's own (`plate btn`), not Cloudscape's.
 */

/** Where the cluster stands: the left edge, as a share of the screen's width.
 *  One number to tune in game, against where the ped stands. */
export const CLUSTER_X = '64%'

/** How often the wheel may zoom: one step per notch, not per event. */
const WHEEL_MS = 80

function spin(delta: number) {
  void fetchNui(CB.LOCKER_SPIN, { delta })
}

function cam(op: 'turn' | 'zoom' | 'reset', d?: 1 | -1) {
  void fetchNui(CB.LOCKER2_CAM, d === undefined ? { op } : { op, d })
}

/** A held rotate: one step on the press, then a steady turn. */
const spinDelay = (n: number) => (n === 1 ? 300 : SPIN_TICK_MS)

function CamBtn({ label, children, onPress, hold }: {
  label: string
  children: ReactNode
  onPress: (n: number) => void
  hold?: boolean
}) {
  const held = useHold(onPress, spinDelay)
  const press = hold ? held : { onClick: () => onPress(0) }
  return (
    <button type="button" className="plate btn lk2-cam-btn" aria-label={label} title={label} {...press}>
      <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">{children}</svg>
    </button>
  )
}

export function CameraStage() {
  const dragging = useRef(false)
  const lastX = useRef(0)
  const lastWheel = useRef(0)
  const onDown = (e: React.PointerEvent) => {
    dragging.current = true
    lastX.current = e.clientX
    try { e.currentTarget.setPointerCapture(e.pointerId) } catch { /* no capture */ }
  }
  const onMove = (e: React.PointerEvent) => {
    if (!dragging.current) return
    const dx = e.clientX - lastX.current
    lastX.current = e.clientX
    if (dx !== 0) spin(dx * 0.4)
  }
  const onUp = (e: React.PointerEvent) => {
    dragging.current = false
    try { e.currentTarget.releasePointerCapture(e.pointerId) } catch { /* already gone */ }
  }
  const onWheel = (e: React.WheelEvent) => {
    if (e.deltaY === 0) return
    const now = Date.now()
    if (now - lastWheel.current < WHEEL_MS) return
    lastWheel.current = now
    cam('zoom', e.deltaY < 0 ? 1 : -1)
  }

  return (
    <>
      <div
        className="absolute inset-0 cursor-ew-resize"
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={onUp}
        onPointerCancel={onUp}
        onWheel={onWheel}
      />
      <div className="lk2-cam" style={{ left: CLUSTER_X }}>
        <CamBtn label={CAM.left} hold onPress={(n) => { if (n === 0) play('ui.select'); spin(n === 0 ? -SPIN_STEP : -SPIN_TICK) }}>
          <path d="M8 7H4V3" /><path d="M4.6 7A8 8 0 1 1 4 12" />
        </CamBtn>
        <CamBtn label={CAM.right} hold onPress={(n) => { if (n === 0) play('ui.select'); spin(n === 0 ? SPIN_STEP : SPIN_TICK) }}>
          <path d="M16 7h4V3" /><path d="M19.4 7A8 8 0 1 0 20 12" />
        </CamBtn>
        <CamBtn label={CAM.turn} onPress={() => { play('ui.select'); cam('turn') }}>
          <path d="M4 10a8 5 0 0 1 16 0" /><path d="M20 14a8 5 0 0 1-16 0" /><path d="M17 6.5 20 10l-4 1" /><path d="M7 17.5 4 14l4-1" />
        </CamBtn>
        <CamBtn label={CAM.zoomIn} onPress={() => { play('ui.select'); cam('zoom', 1) }}>
          <circle cx="10.5" cy="10.5" r="6.5" /><path d="M15.5 15.5 21 21" /><path d="M10.5 7.5v6M7.5 10.5h6" />
        </CamBtn>
        <CamBtn label={CAM.zoomOut} onPress={() => { play('ui.select'); cam('zoom', -1) }}>
          <circle cx="10.5" cy="10.5" r="6.5" /><path d="M15.5 15.5 21 21" /><path d="M7.5 10.5h6" />
        </CamBtn>
        <CamBtn label={CAM.reset} onPress={() => { play('ui.select'); cam('reset') }}>
          <path d="M4 9V4h5" /><path d="M20 9V4h-5" /><path d="M4 15v5h5" /><path d="M20 15v5h-5" /><circle cx="12" cy="12" r="2.5" />
        </CamBtn>
      </div>
    </>
  )
}
