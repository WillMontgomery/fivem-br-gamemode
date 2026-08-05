import type { InvSlot } from '../bridge/types'

/**
 * Item artwork.
 *
 * WHY THESE ARE DRAWN AND NOT GTA'S OWN ICONS: the weapon icons live in the
 * game's texture dictionaries, and CEF cannot read a game txd -- there is no
 * URL that resolves to one. The alternatives are shipping a custom image set
 * (this project is vanilla-assets-only) or drawing them, so they are drawn:
 * inline SVG, no files, no network, scales with the slot.
 *
 * By CATEGORY rather than per weapon. Thirty-nine hand-drawn silhouettes would
 * be thirty-nine chances to be subtly wrong, and at slot size a pistol and a
 * revolver are the same picture anyway. The rarity colour and the label carry
 * the identity; the icon carries "what kind of thing is this".
 */

type Category =
  | 'pistol' | 'smg' | 'rifle' | 'shotgun' | 'sniper' | 'lmg'
  | 'throwable' | 'shield' | 'health' | 'ammo'

/** Weapon id -> category. Ids come from br_lib/config/weapons.lua. */
const WEAPON_CATEGORY: Record<string, Category> = {
  pistol: 'pistol', snspistol: 'pistol', combatpistol: 'pistol',
  pistolmk2: 'pistol', heavypistol: 'pistol', revolver: 'pistol',
  revolvermk2: 'pistol',

  microsmg: 'smg', machinepistol: 'smg', minismg: 'smg', smg: 'smg',
  smgmk2: 'smg', assaultsmg: 'smg', combatpdw: 'smg',

  bullpuprifle: 'rifle', assaultrifle: 'rifle', carbinerifle: 'rifle',
  advancedrifle: 'rifle', carbinemk2: 'rifle', assaultmk2: 'rifle',
  specialcarbine: 'rifle', militaryrifle: 'rifle',

  sawnoff: 'shotgun', pumpshotgun: 'shotgun', assaultshotgun: 'shotgun',
  pumpshotgunmk2: 'shotgun', heavyshotgun: 'shotgun', combatshotgun: 'shotgun',

  marksmanrifle: 'sniper', sniperrifle: 'sniper', marksmanmk2: 'sniper',
  heavysniper: 'sniper',

  mg: 'lmg', gusenberg: 'lmg', combatmg: 'lmg', combatmgmk2: 'lmg',
}

const CONSUMABLE_CATEGORY: Record<string, Category> = {
  minishield: 'shield', shield: 'shield',
  bandage: 'health', medkit: 'health',
}

function categoryOf(slot: InvSlot): Category {
  if (slot.kind === 'ammo') return 'ammo'
  if (slot.kind === 'throwable') return 'throwable'
  if (slot.kind === 'consumable') return CONSUMABLE_CATEGORY[slot.id] ?? 'health'
  return WEAPON_CATEGORY[slot.id] ?? 'rifle'
}

/** Paths are authored in a 24x24 box and scaled by the caller. */
const PATHS: Record<Category, string> = {
  pistol: 'M3 9h9l2 2h3v3h-2l-1 3h-3l-1-3H8l-1 4H4l1-4H3z',
  smg: 'M2 9h13l1 2h5v2h-4v2h-3l-1-2H9v4H6v-4H2z',
  rifle: 'M1 9h16l2 2h4v2h-5v2h-3l-1-2h-3v4h-3v-4H1z',
  shotgun: 'M1 9h20v2H1zm2 3h4l1 3H4zm12-6h6v2h-6z',
  sniper: 'M1 10h6V8h5v2h11v2h-4v3h-3v-3h-3v5H9v-5H1zM8 5h5v2H8z',
  lmg: 'M1 8h15v2h6v2h-5v2h-4v4H8v-4H5v3H2v-3H1zm3 6h3v3H4z',
  throwable: 'M12 3l2 2h-1v2a6 6 0 1 1-2 0V5h-1zM8 12a4 4 0 0 0 8 0z',
  shield: 'M12 2l8 3v7c0 5-4 8-8 10-4-2-8-5-8-10V5z',
  health: 'M9 3h6v6h6v6h-6v6H9v-6H3V9h6z',
  ammo: 'M6 3h4v6l2 3v9H4v-9l2-3zm8 2h4v5l1 2v9h-6v-9l1-2z',
}

export default function ItemIcon({
  slot, size = '1.6rem',
}: { slot: InvSlot; size?: string }) {
  const cat = categoryOf(slot)
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      aria-hidden="true"
      style={{ display: 'block' }}
    >
      {/* currentColor so the caller tints it with the rarity -- no fill
          declaration that CEF could fail to parse. */}
      <path d={PATHS[cat]} fill="currentColor" />
    </svg>
  )
}
