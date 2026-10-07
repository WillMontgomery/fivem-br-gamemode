import type { ReactElement, ReactNode } from 'react'
import { lines, voltsParts, voltsText } from './model'

/**
 * VOLTS, IN THE VOLTS STYLE: the gold, in the page's own font.
 *
 * Round 4 (owner, 2026-10-06): "Any mention of volts must use our proper font
 * for that and the gold color." Round 5, the same day: "change the volts text
 * once more, but this time back to the standard font for the browser instead
 * of our volts font." So the style is the gold the owner gave Volts
 * (`--color-volts`, #d9ae35, ui-src/src/index.css) and nothing else:
 * terminal.css's `.terminal-volts` sets the color, and the font and its
 * weight are the text's around it. EVERY Volts amount the app shows, and the
 * currency's word wherever a line writes it, comes through this file:
 *
 *   VoltsAmount   a figure and the word ("1,250 Volts"): a card's cost
 *   voltsLine     a line of copy with its Volts in the style: a {volts},
 *                 {cost} or {balance} filled with its figure, and the word
 *                 where the line says it -- a page's cost, the confirmation,
 *                 a run's answer (no_volts, the new balance), the privacy
 *                 policy's "your Volts balance"
 *   voltsLines    the same over a '\n' list, one entry per piece
 *
 * The top bar's balance is the one Volts figure Cloudscape takes as a string
 * (a TopNavigation utility's text): App.tsx marks the top bar while the
 * balance is its first item, and terminal.css colors that item the same way.
 * scripts/check-terminal.mjs T12 holds all of it -- a Volts amount drawn
 * any other way fails the build.
 */

/** A Volts figure and the currency's word, in the Volts style. */
export function VoltsAmount(props: { n: number; currency: string }): ReactElement {
  return <span className="terminal-volts">{voltsText(props.n, props.currency)}</span>
}

/** A line with every Volts in it in the Volts style (model.ts `voltsParts`). */
export function voltsLine(text: string, currency: string, amounts: Record<string, number> = {}): ReactNode[] {
  return voltsParts(text, currency, amounts).map((p, i) =>
    p.volts ? <span key={i} className="terminal-volts">{p.text}</span> : p.text)
}

/** A '\n' list of lines, each with its Volts in the Volts style. */
export function voltsLines(text: string, currency: string, amounts: Record<string, number> = {}): ReactNode[][] {
  return lines(text).map((l) => voltsLine(l, currency, amounts))
}
