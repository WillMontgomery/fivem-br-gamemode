import { useRef, type KeyboardEvent, type ReactNode } from 'react'
import { Fit, play } from './deps'

/**
 * TAB AND TABSTRIP (#431): the Season 2 Market's tablist semantics on
 * Broadcast faces. role="tablist", one role="tab" per item with
 * aria-selected, the selected one the only Tab stop (roving tabindex), and
 * Left, Right, Home and End move along it. Every tab is a `btn` (check-ui R3):
 * it brightens, travels and speaks.
 *
 *   design 'plates'  each tab a slanted plate; the selected one lit -- a cyan
 *                    slab, teal fill, white ink; at rest a quiet edge, .62 ink
 *          'blade'   bare words on a hairline; a slanted cyan blade under the
 *                    selected one
 */

export interface TabItem<K extends string> {
  id: K
  /** Existing words only. */
  label: ReactNode
}

export function TabStrip<K extends string>({ tabs, value, onPick, design = 'plates' }: {
  tabs: readonly TabItem<K>[]
  value: K
  onPick: (id: K) => void
  design?: 'plates' | 'blade'
}) {
  const row = useRef<HTMLDivElement>(null)
  const move = (e: KeyboardEvent<HTMLDivElement>) => {
    const at = tabs.findIndex((t) => t.id === value)
    let to = -1
    if (e.key === 'ArrowRight') to = (at + 1) % tabs.length
    else if (e.key === 'ArrowLeft') to = (at - 1 + tabs.length) % tabs.length
    else if (e.key === 'Home') to = 0
    else if (e.key === 'End') to = tabs.length - 1
    const next = tabs[to]
    if (next === undefined) return
    e.preventDefault()
    onPick(next.id)
    row.current?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[to]?.focus()
  }
  return (
    <div ref={row} role="tablist" className={`bc-tabs bc-tabs--${design}`} data-design={design} onKeyDown={move}>
      {tabs.map((t) => (
        <Tab key={t.id} selected={t.id === value} onPick={() => onPick(t.id)}>{t.label}</Tab>
      ))}
    </div>
  )
}

/** One tab. Inside a TabStrip; alone only for a static specimen. */
export function Tab({ selected, onPick, children }: {
  selected: boolean
  onPick?: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={selected}
      tabIndex={selected ? 0 : -1}
      className={`bc-btn bc-tab btn${selected ? ' is-active' : ''}`}
      onPointerEnter={() => play('ui.hover')}
      onClick={() => {
        if (selected) return
        play('ui.select')
        onPick?.()
      }}
    >
      <Fit center>{children}</Fit>
    </button>
  )
}
