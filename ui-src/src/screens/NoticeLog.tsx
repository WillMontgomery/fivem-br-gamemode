import { useEffect, useState } from 'react'
import { useUi } from '../store'
import { TONE_COLOUR } from '../hud/Notices'
import Btn from '../ui/Btn'

/**
 * What you missed.
 *
 * A notice is on screen for four seconds. That is the right length for a line
 * that appears over a firefight and the wrong length for a player who was
 * aiming at somebody when it landed -- the event happened, they saw a flash of
 * something in the corner, and it is gone (user, 2026-08-09). GTA's own pause
 * menu keeps a feed for exactly this reason.
 *
 * IT IS THE SAME EVENTS, NOT A SECOND SYSTEM. Every line here is a notice that
 * was pushed, with its own tone and its own count, written by the store as the
 * notice ARRIVES rather than as it displays -- so a notice that queued behind
 * this very menu is already in the list by the time it is opened.
 *
 * TIME IS RELATIVE, ALWAYS. "16:42" means nothing to somebody who has been in
 * a match for twenty minutes and does not know what time it was when they
 * started; "4m ago" is the question they are actually asking.
 */

/** Re-render cadence for the relative timestamps. */
const TICK_MS = 15_000

function ago(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 10) return 'just now'
  if (s < 60) return `${s}s ago`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ago`
  return `${Math.floor(m / 60)}h ago`
}

export default function NoticeLog() {
  const log = useUi((s) => s.noticeLog)
  const clearLog = useUi((s) => s.clearNoticeLog)

  // The timestamps age while the menu sits open. One interval for the whole
  // list rather than a timer per row -- and at 15s, because the finest
  // resolution any of these labels has is a second and most are minutes.
  const [, setTick] = useState(0)
  useEffect(() => {
    const t = window.setInterval(() => setTick((n) => n + 1), TICK_MS)
    return () => window.clearInterval(t)
  }, [])

  if (log.length === 0) {
    return (
      <div className="plate p-6 flex flex-col gap-2"
           style={{
             ['--edgec' as string]: 'rgba(255,255,255,0.12)',
             ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
             ['--cut-max' as string]: '0.6rem',
           }}>
        <div className="font-display text-[1.15rem] uppercase tracking-[0.08em]">
          Nothing yet
        </div>
        <div className="micro-label" style={{ textTransform: 'none' }}>
          Party events, pickups and match alerts appear here as they happen.
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <div className="micro-label">
          {log.length} {log.length === 1 ? 'notification' : 'notifications'} this session
        </div>
        <Btn variant="ghost" size="sm" cue="ui.back" onPress={clearLog}>
          Clear
        </Btn>
      </div>

      {/* Scrolls INSIDE the pane, never the page: the pause menu is a fixed
          full-screen surface and a page-level scrollbar on it would move the
          tabs off the top of the screen. */}
      <div className="pane flex flex-col gap-1">
        {log.map((n) => {
          const tone = TONE_COLOUR[n.tone ?? 'info']
          return (
            <div
              key={n.id}
              // The same object as the live notice -- .panel with a tone blade
              // on the leading edge -- so a line in the history is recognisably
              // the line that was on screen, not a log entry about it.
              className="panel tscale px-3.5 py-2 text-[0.85rem] text-white/85
                         flex items-center gap-2"
              style={{
                borderLeft: `2px solid ${tone}`,
                borderRadius: '0 var(--r-panel) var(--r-panel) 0',
              }}
            >
              <span className="min-w-0">{n.text}</span>
              {n.count > 1 && (
                <span
                  className="font-display text-[0.85rem] leading-none"
                  style={{ color: tone }}
                >
                  &times;{n.count}
                </span>
              )}
              <span
                className="micro-label ml-auto pl-3 shrink-0"
                style={{ textTransform: 'none' }}
              >
                {ago(Date.now() - n.at)}
              </span>
            </div>
          )
        })}
      </div>
    </div>
  )
}
