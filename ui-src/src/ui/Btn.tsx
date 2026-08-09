import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { ReactNode } from 'react'

/**
 * The button.
 *
 * HeroUI's button is a fine web control and the wrong object for this game: it
 * is rounded, it is quiet, and it sounds like nothing. A front end that wants
 * to feel like a game needs its primary action to look like hardware and to
 * answer when you touch it.
 *
 * THREE THINGS EVERY BUTTON HERE DOES:
 *
 *   * it is a `.plate` -- square, near-opaque, and it BEVELS when it takes
 *     focus, the same language the inventory uses. A player learns the shape
 *     once and it means the same thing everywhere.
 *   * it moves under the press. Not a colour change: a 1px drop and a scale,
 *     so the button feels like it has travel.
 *   * it makes a sound, through Lua's cue table. Hover and press are different
 *     cues, because a menu that only speaks on click feels dead between clicks.
 *
 * The audio goes out through the SFX callback rather than an <audio> tag: Lua
 * owns the cue table and the throttle, so the UI never learns a sound-set name
 * and a wrong one is fixed in a single place.
 */

type Variant = 'primary' | 'default' | 'ghost' | 'danger'

const VARIANT: Record<Variant, { fill: string; edge: string; text: string }> = {
  // The one loud object on a screen. Cyan means "you may act", and there is
  // never more than one of these visible at a time.
  primary: { fill: '#22d3ee', edge: '#67e8f9', text: '#04222a' },
  default: { fill: 'rgba(32,36,50,0.94)', edge: 'rgba(255,255,255,0.30)', text: '#ffffff' },
  ghost:   { fill: 'rgba(20,22,32,0.55)', edge: 'rgba(255,255,255,0.16)', text: 'rgba(255,255,255,0.75)' },
  danger:  { fill: 'rgba(52,20,24,0.94)', edge: '#ef4444', text: '#ffd7d7' },
}

export default function Btn({
  children,
  onPress,
  variant = 'default',
  size = 'md',
  active = false,
  disabled = false,
  full = false,
  cue = 'ui.select',
  title,
}: {
  children: ReactNode
  onPress?: () => void
  variant?: Variant
  size?: 'sm' | 'md' | 'lg' | 'xl'
  /** Selected-in-a-set. Bevels, like every other active plate. */
  active?: boolean
  disabled?: boolean
  full?: boolean
  /** Which cue fires on press. Ready-up gets its own; back gets ui.back. */
  cue?: string
  title?: string
}) {
  const v = VARIANT[variant]

  const pad = {
    sm: 'px-3 py-1.5 text-[0.72rem]',
    md: 'px-4 py-2.5 text-[0.85rem]',
    lg: 'px-6 py-3.5 text-[1.05rem]',
    xl: 'px-8 py-5 text-[1.6rem]',
  }[size]

  const sfx = (c: string) => { void fetchNui(CB.SFX, { cue: c }) }

  return (
    <button
      type="button"
      title={title}
      disabled={disabled}
      onPointerEnter={() => { if (!disabled) sfx('ui.hover') }}
      onClick={() => {
        if (disabled) { sfx('ui.error'); return }
        sfx(cue)
        onPress?.()
      }}
      // .plate carries the shape and the bevel-on-active; `btn` carries the
      // travel. Both are in index.css so the motion vocabulary stays in one
      // file rather than being re-invented per screen.
      className={`plate btn font-display uppercase tracking-[0.1em] ${pad}`
        + `${active ? ' is-active' : ''}${full ? ' w-full' : ''}`
        + `${disabled ? ' btn--off' : ''}`}
      style={{
        ['--plate-fill' as string]: v.fill,
        ['--edgec' as string]: v.edge,
        color: v.text,
      }}
    >
      {children}
    </button>
  )
}
