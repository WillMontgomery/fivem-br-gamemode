import type { ReactNode } from 'react'
import { Fit, play, type Cue } from './deps'

/**
 * LISTROW (#431): the pause list's and the locker's line. A label (Barlow 700,
 * uppercase), a summary that takes the room the label leaves (one line or not
 * drawn) and brightens when the row is active, and a trailing slot (a Button,
 * a KeyCap, a Numeral) behind a divider.
 *
 *   state  'rest' | 'active' (teal, a cyan slab) | 'confirm' (danger ink)
 *   Hover is the `btn` brighten, on a row you can press.
 */
export function ListRow({ label, summary, trailing, state = 'rest', onPress, cue = 'ui.select' }: {
  label: ReactNode
  summary?: ReactNode
  trailing?: ReactNode
  state?: 'rest' | 'active' | 'confirm'
  onPress?: () => void
  cue?: Cue
}) {
  const cls = `bc-btn bc-listrow${state !== 'rest' ? ` is-${state}` : ''}`
  const inner = (
    <>
      <span className="bc-listrow__text">
        <Fit className="bc-listrow__label">{label}</Fit>
        {summary !== undefined && <Fit drop className="bc-listrow__sum">{summary}</Fit>}
      </span>
      {trailing !== undefined && <span className="bc-listrow__trail">{trailing}</span>}
    </>
  )
  if (!onPress) return <div className={cls}>{inner}</div>
  return (
    <button
      type="button"
      className={`${cls} btn`}
      onPointerEnter={() => play('ui.hover')}
      onClick={() => { play(cue); onPress() }}
    >
      {inner}
    </button>
  )
}
