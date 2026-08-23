import { useEffect, useState } from 'react'
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
  | 'launcher' | 'minigun' | 'railgun'
  | 'melee' | 'throwable' | 'shield' | 'health' | 'ammo'

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

  // ═══ THE AIRDROP SHELF, WHICH HAD NO PICTURE AT ALL ═══
  //
  // Owner, 2026-08-22: "railgun and grenade launcher do not have images."
  //
  // These four are BR.Config.AirdropWeapons -- rpg, grenadelauncher, railgun,
  // minigun -- added with the supply drops and never given artwork. They were
  // not drawing a broken image: they were falling through `categoryOf`'s
  // `?? 'rifle'` default, so a railgun drew an assault rifle. Two silent
  // fallbacks stacked (the PNG's onError, then the category default) and
  // between them there was no error anywhere, which is why this reached a
  // playtest. tools/check_weapons.lua now fails the build on it.
  //
  // THREE CATEGORIES RATHER THAN ONE, against this file's own "by category"
  // rule, because that rule's justification does not hold here: a pistol and a
  // revolver are the same picture at slot size, but a shoulder tube, a rotary
  // barrel cluster and a squared-off rail are three plainly different objects,
  // and the owner named two of them separately. Grouping them would answer the
  // complaint with a different wrong picture.
  rpg: 'launcher', grenadelauncher: 'launcher',
  minigun: 'minigun',
  railgun: 'railgun',

  // MELEE, which had art but no drawn fallback. All eleven resolved through
  // the same `?? 'rifle'` default, so any one of them whose PNG failed to load
  // would draw a rifle. They have a shape of their own now.
  knuckle: 'melee', bottle: 'melee', crowbar: 'melee', bat: 'melee',
  wrench: 'melee', dagger: 'melee', knife: 'melee', switchblade: 'melee',
  machete: 'melee', hatchet: 'melee', battleaxe: 'melee',
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
  // A shoulder tube with a ROUND warhead sat on the muzzle.
  //
  // The warhead was a cone through two drafts and both read as an ARROW --
  // a triangle flush against the end of a bar is a chevron, and at slot size
  // that is all the eye gets. A circle cannot be read as an arrowhead, which
  // is the entire reason it is a circle.
  launcher: 'M2 10h11v4H9l-1 4H6l1-4H2zM18 7a5 5 0 1 1 0 10 5 5 0 0 1 0-10z',
  // Rotary barrels. The three separated bars are the whole identity -- a solid
  // block would read as an LMG.
  minigun: 'M2 8h9v9H2zm2 9h3v4H4zm7-8h11v1.5H11zm0 2.75h11v1.5H11zm0 2.75h11v1.5H11z',
  // The armature, which is the thing itself: two long parallel rails bridged
  // at the muzzle, on a blocky receiver.
  //
  // A scope on a barrel -- the first draft -- was a sniper rifle, which the
  // set already has. Two bars alone would be the minigun's three bars minus
  // one. The BRIDGE closing the far end is what neither of those has.
  railgun: 'M2 9h10v7H2zm2 7h3v4H4zM12 9.5h9V8h2v9h-2v-1.5h-9V14h9v-3h-9z',
  // A blade on a handle -- the one shape that covers a knife, a machete and a
  // bat well enough at slot size, where the label carries the rest.
  melee: 'M17 2l5 5-9 9-5-5zM8 13l3 3-4 4-3-3z',
  throwable: 'M12 3l2 2h-1v2a6 6 0 1 1-2 0V5h-1zM8 12a4 4 0 0 0 8 0z',
  shield: 'M12 2l8 3v7c0 5-4 8-8 10-4-2-8-5-8-10V5z',
  health: 'M9 3h6v6h6v6h-6v6H9v-6H3V9h6z',
  ammo: 'M6 3h4v6l2 3v9H4v-9l2-3zm8 2h4v5l1 2v9h-6v-9l1-2z',
}

/**
 * REAL ARTWORK IF IT IS THERE, drawn shapes if it is not.
 *
 * Weapon PNGs go in `ui-src/public/items/<id>.png`, where `<id>` is the item
 * id from br_lib (`carbinerifle.png`, `medkit.png`, ...). Vite copies
 * `public/` verbatim into the build, so they end up at `items/<id>.png`
 * alongside index.html and resolve without any import or bundler config.
 *
 * The fallback is not a nicety: a missing file must never leave an empty
 * square, and the set will always be incomplete somewhere (there is no
 * artwork for an ammo pool). `onError` swaps to the drawn icon, so adding a
 * PNG is the entire act of adopting it -- no list to update in two places.
 */
function iconUrl(slot: InvSlot): string | null {
  if (slot.kind === 'ammo') return null
  return `items/${slot.id}.png`
}

/** The fists slot has no item, so it is drawn from the same set by name. */
export function FistIcon({ size = '1.6rem' }: { size?: string }) {
  const [failed, setFailed] = useState(false)
  if (failed) {
    return (
      <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden="true"
           style={{ display: 'block' }}>
        <path d="M7 10V6a2 2 0 1 1 4 0v3h1V5a2 2 0 1 1 4 0v4h1V7a2 2 0 1 1 4 0v8a6 6 0 0 1-6 6h-3a6 6 0 0 1-6-6v-3a2 2 0 1 1 4 0z"
              fill="currentColor" />
      </svg>
    )
  }
  return (
    <img src="items/fists.png" alt="" width={size} height={size}
         onError={() => setFailed(true)}
         style={{ display: 'block', width: size, height: size,
                  objectFit: 'contain' }} />
  )
}

export default function ItemIcon({
  slot, size = '1.6rem',
}: { slot: InvSlot; size?: string }) {
  const cat = categoryOf(slot)
  const [failed, setFailed] = useState(false)
  const url = iconUrl(slot)

  // The id changes when the slot's contents change; a stale `failed` would
  // suppress the artwork of the NEXT item to land in this slot.
  useEffect(() => setFailed(false), [slot.id])

  if (url && !failed) {
    return (
      <img
        src={url}
        alt=""
        width={size}
        height={size}
        onError={() => setFailed(true)}
        style={{ display: 'block', width: size, height: size,
                 objectFit: 'contain' }}
      />
    )
  }

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
