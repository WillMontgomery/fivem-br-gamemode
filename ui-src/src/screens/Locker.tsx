import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'
import Ring from '../hud/Ring'

/**
 * The locker.
 *
 * THE RIGHT TWO THIRDS OF THIS SCREEN ARE EMPTY ON PURPOSE, and that emptiness
 * is the feature: it is where the real ped is standing, in the real world,
 * lit by the real time of day, framed by the lobby camera. Every character
 * preview drawn INSIDE a panel is a picture of a character; this is the
 * character. That is the whole reason the lobby was rebuilt as a character
 * shot first (see br_core/client/lobbycam.lua) -- the locker is what that
 * camera was for.
 *
 * SO THERE IS NO PREVIEW PANE, AND NO CONFIRM STEP. Clicking a name swaps the
 * ped instantly. A locker with an Apply button is a locker where you cannot
 * see what you are applying, and a locker with a thumbnail grid is a locker
 * that has to ship thumbnails -- which this project cannot, being
 * vanilla-assets-only.
 *
 * DRAG ANYWHERE ON THE EMPTY SIDE TO TURN THEM. Pointer capture, so a drag
 * that leaves the window still ends; deltas rather than absolute angles, so
 * the ped never snaps when the pointer re-enters.
 */

export default function Locker() {
  const locker = useUi((s) => s.locker)
  const dragging = useRef(false)
  const lastX = useRef(0)

  const close = () => { void fetchNui(CB.LOCKER_FOCUS, { open: false }) }

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      play('ui.back')
      close()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  const onDown = (e: React.PointerEvent) => {
    dragging.current = true
    lastX.current = e.clientX
    // Capture is a nicety -- it keeps a drag alive past the window edge --
    // and it THROWS if the pointer is not currently active, which a synthetic
    // event or a pointer that vanished mid-gesture both produce. Losing the
    // capture costs a drag that stops at the edge; letting it throw costs the
    // whole screen.
    try { e.currentTarget.setPointerCapture(e.pointerId) } catch { /* no capture */ }
  }
  const onMove = (e: React.PointerEvent) => {
    if (!dragging.current) return
    const dx = e.clientX - lastX.current
    lastX.current = e.clientX
    if (dx === 0) return
    // 0.4 degrees per pixel: a full turn is about a 900px drag, which is a
    // comfortable sweep across the empty side rather than a flick that spins
    // the character three times.
    void fetchNui(CB.LOCKER_SPIN, { delta: dx * 0.4 })
  }
  const onUp = (e: React.PointerEvent) => {
    dragging.current = false
    try { e.currentTarget.releasePointerCapture(e.pointerId) } catch { /* already gone */ }
  }

  return (
    <div className="interactive fixed inset-0 z-50">
      {/* THE DRAG SURFACE IS THE WHOLE SCREEN, and it sits UNDER the list --
          so dragging works everywhere the character might be, including
          behind the panel's translucent edge, without the list's buttons
          losing their clicks. */}
      <div
        className="absolute inset-0 cursor-ew-resize"
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={onUp}
        onPointerCancel={onUp}
      />

      {/* A scrim on the LEFT ONLY, fading to nothing by a third of the way
          across: the list needs something to sit on, and the character needs
          the rest of the frame. A full-screen scrim would dim the one thing
          this screen exists to show. */}
      <div
        className="absolute inset-y-0 left-0 w-[46%] pointer-events-none"
        style={{
          background: 'linear-gradient(90deg, rgba(6,8,14,0.94) 0%, '
                    + 'rgba(6,8,14,0.86) 55%, rgba(6,8,14,0) 100%)',
        }}
      />

      <div
        className="absolute inset-y-0 left-0 w-[34rem] max-w-[52vw]
                   flex flex-col justify-center px-[3.5rem] py-[3rem]
                   pointer-events-none"
      >
        <div className="pointer-events-auto">
          <div className="micro-label">Locker</div>
          <h2 className="font-display text-[3rem] uppercase tracking-[0.1em] leading-none mt-1">
            Character
          </h2>
          <p className="micro-label mt-2">
            Drag anywhere to turn them &middot; changes apply instantly
          </p>

          <div
            className="thin-scroll overflow-y-auto mt-6 pr-2"
            style={{ maxHeight: '48vh' }}
          >
            <div className="grid grid-cols-2 gap-2">
              {locker.peds.map((p) => {
                const on = p.id === locker.chosen
                // STREAMING IN. A model that is not already in memory takes a
                // beat to arrive, and a button that looks identical before and
                // after the click reads as a button that did nothing -- so
                // people click again, which is the race the Lua side now
                // absorbs. This is the half that stops them wanting to.
                const busy = locker.loading === p.id
                return (
                  <button
                    key={p.id}
                    type="button"
                    className={`btn plate px-3 py-2.5 text-left${on ? ' is-active' : ''}`}
                    style={{
                      ['--edgec' as string]: on
                        ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
                      ['--plate-fill' as string]: on
                        ? 'rgba(12,58,72,0.94)' : 'rgba(24,28,40,0.92)',
                      ['--cut-max' as string]: '0.5rem',
                    }}
                    onPointerEnter={() => play('ui.hover')}
                    // stopPropagation on the pointer events, not just the
                    // click: the drag surface underneath treats a press as
                    // the start of a turn, so without this picking a
                    // character also spins them.
                    onPointerDown={(e) => e.stopPropagation()}
                    onPointerUp={(e) => e.stopPropagation()}
                    onClick={() => {
                      play('ui.select')
                      void fetchNui(CB.LOCKER_PICK, { id: p.id })
                    }}
                  >
                    <span
                      className="flex items-center gap-2 text-[0.95rem] tscale"
                      style={{ color: on ? 'var(--color-royale-accent)' : '#ffffff' }}
                    >
                      {p.name}
                      {/* The loading ring the rest of the interface uses, at
                          label size. Same object, same meaning: something is
                          happening and it is not finished. */}
                      {busy && <Ring size={0.85} stroke={0.16} label="Loading" />}
                    </span>
                  </button>
                )
              })}
            </div>
          </div>

          <div className="mt-6">
            <Btn variant="primary" size="lg" cue="ui.back" onPress={() => { close() }}>
              Done
            </Btn>
          </div>
        </div>
      </div>
    </div>
  )
}
