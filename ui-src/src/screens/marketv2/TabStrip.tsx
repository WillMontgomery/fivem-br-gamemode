import { useRef, type KeyboardEvent } from 'react'
import { play } from '../../audio/cues'
import { TAB_LABEL } from './copy'
import type { TabDesign, TabKind } from './model'

/**
 * THE MARKET'S TABS (#411), in one of three designs (model.ts TAB_DESIGNS),
 * drawn by market.css's `.mk2-tabs--<design>` and nothing else.
 *
 * OUR OWN TABLIST, NOT CLOUDSCAPE'S. Cloudscape's tab header scrolls its row
 * inside a box that clips -- the cut and the edges of a tab sitting on that
 * box's edge were cut with it -- and steps in with scroll arrows once the
 * labels outgrow it; none of the three designs could be drawn through it
 * whole. This is the tablist pattern itself: role="tablist", one role="tab"
 * per kind with aria-selected, the selected one the only stop for Tab, and
 * Left, Right, Home and End move along it. Every tab is a `btn` (check-ui
 * R3): it brightens, travels and speaks like every lobby button.
 *
 * CORNERS, AS EVERYWHERE ON THIS SCREEN: the selected tab is cut, the rest
 * square (owner: "let's keep 'em cut where they are today").
 */
export function TabStrip({ tabs, tab, design, onPick }: {
  tabs: readonly TabKind[]
  tab: TabKind
  design: TabDesign
  onPick: (k: TabKind) => void
}) {
  const row = useRef<HTMLDivElement>(null)

  const move = (e: KeyboardEvent<HTMLDivElement>) => {
    const at = tabs.indexOf(tab)
    let to = -1
    if (e.key === 'ArrowRight') to = (at + 1) % tabs.length
    else if (e.key === 'ArrowLeft') to = (at - 1 + tabs.length) % tabs.length
    else if (e.key === 'Home') to = 0
    else if (e.key === 'End') to = tabs.length - 1
    const next = tabs[to]
    if (next === undefined) return
    e.preventDefault()
    onPick(next)
    row.current?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[to]?.focus()
  }

  return (
    <div ref={row} role="tablist" className={`mk2-tabs mk2-tabs--${design}`} data-design={design} onKeyDown={move}>
      {tabs.map((k) => {
        const on = k === tab
        return (
          <button
            key={k}
            type="button"
            role="tab"
            aria-selected={on}
            tabIndex={on ? 0 : -1}
            // THE SELECTED TAB IS THE CUT ONE: the lobby's plate, `is-active`.
            className={`mk2-tab btn plate font-display uppercase${on ? ' is-active' : ''}`}
            onPointerEnter={() => play('ui.hover')}
            onClick={() => { if (!on) onPick(k) }}
          >
            {TAB_LABEL[k]}
          </button>
        )
      })}
    </div>
  )
}
