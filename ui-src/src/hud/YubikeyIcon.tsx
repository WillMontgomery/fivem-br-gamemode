/**
 * THE SEASON 2 YUBIKEY (#396), EQUIPPED.
 *
 * Owner, 2026-10-04: "the Yubikey is an item they own and must be displayed as
 * an icon somewhere on the screen to show it's equipped, however it doesn't
 * take up an inventory slot" -- and "In squads, teammates can see who holds a
 * key: this could be multiple per squad!"
 *
 * TWO MARKS. YubikeyIcon is the holder's own, in the inventory's column;
 * YubikeyMark sits beside a squadmate's name in the squad panel and draws the
 * string Lua hands it -- br_lib/config/terminals.lua's `art.hudGlyph`. Neither
 * carries a caption.
 *
 * THE HOLDER'S ICON IS THE OWNER'S OWN IMAGE (2026-10-06, round 5: "please use
 * this icon for the yubikey when it's possessed. When displayed in the bottom
 * right corner by the inventory slots, make it 25% larger than it's currently
 * drawn, and make it have no background (the image background is already
 * transparent)"; "That image is mine - it's our exact prop, just turned into an
 * icon so it looks familiar"). His 159x159 render of the blitz_seckey prop,
 * public/items/yubikey.png -- served as items/yubikey.png beside the other item
 * art, the key's item id being `yubikey` -- drawn at 3rem square: 25% over the
 * 2.4rem plate it replaced, and with NO PLATE behind it, the image's own
 * transparency over the game. Lua's glyph still decides WHETHER it is drawn
 * (Hud.tsx), and still draws the squad panel's mark, which is unchanged.
 *
 * NEITHER RENDERS FOR AN ABSENT GLYPH, the panel's standing rule for a field
 * Lua did not send (see LevelMark). Absent is a player with no key, or a
 * Season 1 server.
 */

/** The owner's image of the key, at its item id (public/items/README.md). */
export const YUBIKEY_ICON_SRC = 'items/yubikey.png'

/**
 * The size it is drawn at: the 2.4rem plate it replaced, 25% larger (owner,
 * round 5). In rem, so it follows the player's interface scale as the
 * inventory bar beside it does.
 */
export const YUBIKEY_ICON_SIZE = '3rem'

/** The holder's own icon: the owner's image, no plate, above the inventory bar. */
export function YubikeyIcon() {
  return (
    <img
      src={YUBIKEY_ICON_SRC}
      alt=""
      aria-hidden
      draggable={false}
      className="block shrink-0"
      style={{ width: YUBIKEY_ICON_SIZE, height: YUBIKEY_ICON_SIZE, objectFit: 'contain' }}
    />
  )
}

/**
 * The mark beside a squadmate's name. `align-self: center` for VoiceMark's
 * reason: the name is the row's baseline, and a mark that set it would drag
 * every plate's height with it.
 */
export function YubikeyMark({ glyph }: { glyph: string }) {
  return (
    <span
      className="leading-none shrink-0"
      style={{
        fontSize: '0.72rem',
        alignSelf: 'center',
        color: 'var(--color-royale-accent)',
        textShadow: 'var(--shadow-text)',
      }}
      aria-hidden
    >
      {glyph}
    </span>
  )
}

/**
 * A TERMINAL BOUNTY (#396) on this squadmate: the owner's spec, "Squad panel:
 * shows the bounty". Beside their name, after the key mark, in the same size;
 * the danger color, because it is the one mark on the row that says the mate
 * is on every enemy's map. The glyph is Lua's (`art.bountyGlyph`, a
 * placeholder), and there is no caption.
 */
export function BountyMark({ glyph }: { glyph: string }) {
  return (
    <span
      className="leading-none shrink-0"
      style={{
        fontSize: '0.72rem',
        alignSelf: 'center',
        color: 'var(--color-danger)',
        textShadow: 'var(--shadow-text)',
      }}
      aria-hidden
    >
      {glyph}
    </span>
  )
}
