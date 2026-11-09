import { ab } from '../../ui/broadcast'
import { KeyCap } from '../../ui/KeyCap'

/**
 * A SLOT'S KEY (#431), on the Broadcast hotbar and on the TAB page's cards.
 *
 * The owner, 2026-11-03: "the 'uncommon' and 1/2/3/4/5 numbers are hard to
 * read". They were the kit's Tag chip at --bc-fs-tag (9.6 px of Anton at
 * 1080p, dark on a pale chip). This is the project's one key glyph instead
 * (ui/KeyCap.tsx): white Anton on a dark plate with a lit edge, sized by the
 * caller.
 *
 * THE KEY COMES FROM THE BINDING (KeyCap's rule, #209): the cap names the
 * slot's command, brslot1..brslot5 (br_core/client/keybinds.lua), so it reads
 * 1-5 on the default binding, follows a rebind live, and draws KeyCap's dash
 * for a slot nothing is bound to. Never a literal digit.
 *
 * IN HAND IT IS LIT: KeyCap's own lit state, the kit's accent fill, edge and
 * ink in the three inline values the cap writes anyway, so nothing here has
 * to outrank them. `beat` pops it when the hand comes to it: the kit's pop,
 * restarted by an A/B class.
 *
 * `fixed` pins it to its size whatever the player's text setting: a cap in the
 * bar's foot strip sits in a plate sized to its contents, beside a numeral that
 * does not scale either. On the page it scales, as KeyCap does in a sentence.
 */
export function SlotKey({ index, held, fs, beat = 0, fixed = false }: {
  /** 1-5: the slot, and the brslot command its key is read from. */
  index: number
  held: boolean
  /** The cap's type size (KeyCap's one dimension): a kit token. */
  fs: string
  beat?: number
  fixed?: boolean
}) {
  return (
    <span className={`binv-key${fixed ? ' binv-key--fixed' : ''}${ab('is-pick', beat)}`}>
      <KeyCap command={`brslot${index}`} fs={fs} lit={held} />
    </span>
  )
}
