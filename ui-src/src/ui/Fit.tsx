import { useLayoutEffect, useRef, type CSSProperties, type ReactNode } from 'react'
import { watchFit } from './labelFit'

/**
 * A SINGLE-LINE LABEL: drawn whole on one line, or not drawn (ui/labelFit.ts).
 *
 * Every label that sits in a box it does not size -- a button in a row, a name
 * in a panel, a tab in a strip -- goes through this, and `Btn` puts every
 * button's label through it. Text that is MEANT to wrap is prose: it is not a
 * Fit, and it says so with `data-wrap` (scripts/check-layout.mjs reads it).
 *
 * `drop` is the secondary part of a label -- the "· queued" after a name, the
 * unit after a number. It gives up its room before anything beside it does
 * (index.css `.fit--drop`), so when a row runs short the detail goes and the
 * name stays.
 *
 * The room is a block by default; `inline` makes it an inline one capped at
 * its line, for a label that sits in running text or beside an icon. The
 * label sits at the start of its room; `center` centers it (Btn's labels).
 */
export default function Fit({
  children, className, style, drop = false, inline = false, center = false, title, tut,
}: {
  children: ReactNode
  className?: string
  style?: CSSProperties
  drop?: boolean
  inline?: boolean
  center?: boolean
  title?: string
  /** The walkthrough's anchor name (`data-tut`), when a card points at it. */
  tut?: string
}) {
  const ref = useRef<HTMLSpanElement>(null)
  useLayoutEffect(() => (ref.current ? watchFit(ref.current) : undefined), [])
  return (
    <span
      ref={ref}
      title={title}
      style={style}
      data-tut={tut}
      className={`fit${drop ? ' fit--drop' : ''}${inline ? ' fit--inline' : ''}${center ? ' fit--center' : ''}${
        className ? ` ${className}` : ''}`}
    >
      <span className="fit-in">{children}</span>
    </span>
  )
}
