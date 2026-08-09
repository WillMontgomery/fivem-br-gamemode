import { useEffect, useRef, useState } from 'react'
import { useNuiEvent } from '../bridge/useNuiEvent'


/**
 * The two moments that were missing.
 *
 * Landing a shot and killing someone are the highest-energy events in a battle
 * royale and neither had any UI at all: your own kill looked exactly like
 * everyone else's, a 13px line in the corner.
 *
 * Both come off `DAMAGE_FEED`, which the server has been sending to the shooter
 * since M6 -- amount, headshot, whether it killed -- and which nothing has ever
 * consumed. It exists precisely because taking damage away from the engine took
 * this feedback with it.
 *
 * NOT IN THE STORE. These are fire-and-forget events with no state anyone else
 * reads; putting them in zustand would re-render every subscriber on every
 * bullet. The component owns them and the HUD never knows.
 *
 * The audio for both fires from Lua (BR.Sfx, throttled at 60ms) -- engine audio
 * ducks against gunfire and a browser tag does not.
 */

/** How long a marker lives. Short: it fires hundreds of times a match. */
const MARK_MS = 420
/** How long the banner holds. Long enough to read a name, not to be in the way. */
const BANNER_MS = 1700

export default function HitFeedback() {
  // A counter rather than a boolean: remounting on a key is how every other
  // animation here is retriggered, and consecutive hits must restart the
  // animation rather than be swallowed by the one still playing.
  const [mark, setMark] = useState<{ id: number; crit: boolean; killed: boolean } | null>(null)
  const [banner, setBanner] = useState<{ id: number; name: string } | null>(null)
  const seq = useRef(0)
  const markTimer = useRef(0)
  const bannerTimer = useRef(0)

  // The kind is the generic; the payload type is derived from the Envelope
  // union, so `hit` only compiles once types.ts declares it.
  useNuiEvent('hit', (d) => {
    seq.current += 1
    const id = seq.current

    // The KILL_FEED sender carries a name and only a name -- that is the
    // banner. The DAMAGE_FEED sender carries the numbers and drives the marker.
    if (d.name) {
      setBanner({ id, name: d.name })
      window.clearTimeout(bannerTimer.current)
      bannerTimer.current = window.setTimeout(() => setBanner(null), BANNER_MS)
      return
    }

    setMark({ id, crit: !!d.headshot, killed: !!d.killed })
    window.clearTimeout(markTimer.current)
    markTimer.current = window.setTimeout(() => setMark(null), MARK_MS)
  })

  useEffect(() => () => {
    window.clearTimeout(markTimer.current)
    window.clearTimeout(bannerTimer.current)
  }, [])

  return (
    <>
      {/* THE HITMARKER. Dead centre, four strokes, no panel and no text --
          it has to be readable in the quarter-second it exists, over whatever
          the player happens to be aiming at.

          Red on a kill, brand cyan on a headshot, white otherwise: three
          states the eye separates without reading anything. */}
      {mark && (
        <svg
          key={mark.id}
          className="hitmarker"
          viewBox="0 0 34 34"
          aria-hidden="true"
          style={{
            stroke: mark.killed
              ? 'var(--color-danger)'
              : mark.crit ? 'var(--color-royale-accent)' : '#ffffff',
            // A kill is bigger. The size difference is what makes "they went
            // down" legible without a second cue.
            width: mark.killed ? '2.6rem' : '2rem',
            height: mark.killed ? '2.6rem' : '2rem',
          }}
        >
          <line x1="6" y1="6" x2="12.5" y2="12.5" />
          <line x1="28" y1="6" x2="21.5" y2="12.5" />
          <line x1="6" y1="28" x2="12.5" y2="21.5" />
          <line x1="28" y1="28" x2="21.5" y2="21.5" />
        </svg>
      )}

      {/* THE ELIMINATION BANNER. Centre-lower, out of the sightline but in the
          same glance as the crosshair. Distinct from the kill feed, which
          stays the running log of OTHER people's kills -- your own deserves a
          moment, and it is the difference between a scoreboard and a game. */}
      {banner && (
        <div key={banner.id} className="elim-banner" aria-live="polite">
          <div className="elim-banner__label">Eliminated</div>
          <div className="elim-banner__name">{banner.name}</div>
        </div>
      )}
    </>
  )
}
