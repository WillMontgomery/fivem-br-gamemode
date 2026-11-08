import type { ReactNode } from 'react'
import { Fit, play, type Cue } from './deps'
import { toneColor, vars, type Tone } from './util'

/**
 * BUTTON (#431): ui/Btn's contract, exactly -- variant, size, active,
 * disabled, full, cue, title -- on a Broadcast face: a slanted plate with a
 * slab in the variant's color. Primary is cyan with its ink, and there is
 * never more than one on a screen ("you may act").
 *
 * It keeps everything that makes a button here a button: the `btn` class
 * (index.css: the 1px travel and scale on press, the hover brighten, the focus
 * ring -- check-ui R3), the cues through play() (hover, the press cue, an
 * error on a disabled press), and a label through Fit (one line, or not
 * drawn). The ring is drawn on the slanted face rather than the upright box.
 */

export type ButtonVariant = 'primary' | 'default' | 'ghost' | 'danger'
export type ButtonSize = 'sm' | 'md' | 'lg' | 'xl'

export function Button({
  children, onPress, variant = 'default', size = 'md', active = false, disabled = false, full = false,
  cue = 'ui.select', title,
}: {
  children: ReactNode
  onPress?: () => void
  variant?: ButtonVariant
  size?: ButtonSize
  /** Selected-in-a-set: the lit face (teal, a cyan slab). */
  active?: boolean
  disabled?: boolean
  full?: boolean
  /** Which cue fires on press. */
  cue?: Cue
  title?: string
}) {
  return (
    <button
      type="button"
      title={title}
      disabled={disabled}
      onPointerEnter={() => { if (!disabled) play('ui.hover') }}
      onClick={() => {
        if (disabled) { play('ui.error'); return }
        play(cue)
        onPress?.()
      }}
      className={`bc-btn btn bc-btn--${variant} bc-btn--${size}${active ? ' is-active' : ''}`
        + `${full ? ' bc-btn--full' : ''}${disabled ? ' btn--off' : ''}`}
    >
      <Fit center>{children}</Fit>
    </button>
  )
}

/**
 * A CARD'S ACTION (#431): a small full-width plate whose edge and ink speak in
 * the action's color, as the Market's do today -- a price in the Volts gold
 * (`volts`: every Volts amount, the owner's pick; off when the balance cannot
 * cover it), equip in hp, unequip and equipped in cyan, replace in victory
 * gold (today's), cancel in white .6.
 */
export function CardAction({ children, tone, onPress, disabled = false, active = false, cue = 'ui.select', title }: {
  children: ReactNode
  tone: Tone | (string & {})
  onPress?: () => void
  disabled?: boolean
  active?: boolean
  cue?: Cue
  title?: string
}) {
  return (
    <button
      type="button"
      title={title}
      disabled={disabled}
      onPointerEnter={() => { if (!disabled) play('ui.hover') }}
      onClick={() => {
        if (disabled) { play('ui.error'); return }
        play(cue)
        onPress?.()
      }}
      className={`bc-btn btn bc-btn--tone bc-btn--sm bc-btn--full${active ? ' is-active' : ''}${disabled ? ' btn--off' : ''}`}
      style={vars({ '--bc-tone': toneColor(tone) })}
    >
      <Fit center>{children}</Fit>
    </button>
  )
}
