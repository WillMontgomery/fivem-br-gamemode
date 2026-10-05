/**
 * THE SEASON 2 YUBIKEY (#396), EQUIPPED.
 *
 * Owner, 2026-10-04: "the Yubikey is an item they own and must be displayed as
 * an icon somewhere on the screen to show it's equipped, however it doesn't
 * take up an inventory slot" -- and "In squads, teammates can see who holds a
 * key: this could be multiple per squad!"
 *
 * TWO MARKS, ONE GLYPH. YubikeyIcon is the holder's own, a plate in the
 * inventory's column; YubikeyMark sits beside a squadmate's name in the squad
 * panel. Both draw the string Lua hands them -- br_lib/config/terminals.lua's
 * `art.hudGlyph`, a placeholder until the owner's icon arrives -- so there is
 * no art here to drift from the config, and no word: neither carries a
 * caption.
 *
 * NEITHER RENDERS FOR AN ABSENT GLYPH, the panel's standing rule for a field
 * Lua did not send (see LevelMark). Absent is a player with no key, or a
 * Season 1 server.
 */

/** The holder's own icon: a small square plate, above the inventory bar. */
export function YubikeyIcon({ glyph }: { glyph: string }) {
  return (
    <div
      className="plate flex items-center justify-center shrink-0"
      style={{ width: '2.4rem', height: '2.4rem' }}
      aria-hidden
    >
      <span
        className="leading-none"
        style={{
          fontSize: '1.45rem',
          color: 'var(--color-royale-accent)',
          textShadow: 'var(--shadow-text)',
        }}
      >
        {glyph}
      </span>
    </div>
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
