import { useEffect, useState } from 'react'
import type { InvSlot } from '../bridge/types'

/**
 * Item artwork.
 *
 * WEAPONS ARE PHOTOGRAPHS, NOT DRAWINGS. Owner, 2026-08-22: "We need to not
 * draw any weapons as SVGs and only use pngs." Every weapon that can occupy a
 * slot -- the firearms, the airdrop shelf, melee, throwables and fists -- ships
 * a PNG at `ui-src/public/items/<id>.png`, and tools/check_weapons.lua fails
 * the build if one is missing from either that directory or the built bundle.
 * Where the art comes from, and on what terms, is recorded in that directory's
 * README.
 *
 * THIS FILE USED TO DRAW TEN WEAPON SILHOUETTES and choose between them with
 * `WEAPON_CATEGORY[slot.id] ?? 'rifle'`. That default is the whole reason this
 * changed: an id missing from the map took the fallback, so a railgun drew a
 * confident assault rifle -- not a broken image, not an empty square, a
 * correct-LOOKING picture of the wrong gun, which no one can catch by looking
 * at the screen. Both the silhouettes and the map that chose between them are
 * gone, so there is no longer any code path that answers "what weapon is this"
 * with a drawing.
 *
 * WHAT IS STILL DRAWN, deliberately, and none of it is a weapon:
 *
 *   * the consumables -- shield, minishield, bandage, medkit. These have no
 *     photographs and never did; a shield and a cross are symbols rather than
 *     objects, so drawing them is the right answer rather than a stopgap.
 *   * ammo, which has no artwork BY DESIGN -- a pooled ammo count is not a
 *     thing that can be photographed -- and so never even attempts a file.
 *   * `missing`, the placeholder, explained where it is defined.
 */

/** The drawn set. Nothing in it is a weapon, and nothing added to it may be. */
type DrawnIcon = 'shield' | 'health' | 'ammo' | 'missing'

/** Consumable id -> drawn icon. Ids come from br_lib/config/loot.lua. */
const CONSUMABLE_ICON: Record<string, DrawnIcon> = {
  minishield: 'shield', shield: 'shield',
  bandage: 'health', medkit: 'health',
}

/**
 * WHAT A MISSING PICTURE LOOKS LIKE. A decision, not an accident.
 *
 * For anything in the weapon tables this should be unreachable: a weapon with
 * no PNG is a red build, so a missing file cannot get as far as a player. The
 * placeholder still has to exist, because a file that IS committed can still
 * fail to decode in CEF, and both of the other candidates for that case are
 * worse than admitting it:
 *
 *   * draw the weapon -- ruled out by the owner, and it is exactly what put an
 *     assault rifle in the railgun's slot;
 *   * draw nothing -- an empty square is indistinguishable from an EMPTY SLOT,
 *     so the player reads "I am not carrying anything" rather than "this one
 *     picture failed". The old README promised a missing file would never
 *     degrade to a blank square, and that promise is worth keeping.
 *
 * An empty frame with a slash through it is neither. It says a picture is
 * missing without claiming to know what the picture would have been. It is
 * also, on purpose, not weapon-shaped -- so if it ever does appear in a slot it
 * reads as a fault rather than as an unusual gun.
 *
 * NOT TEXT. No "?" and no words: the frame carries it, and the slot's own label
 * already says what the item is.
 */

/** Paths are authored in a 24x24 box and scaled by the caller. */
const PATHS: Record<DrawnIcon, string> = {
  shield: 'M12 2l8 3v7c0 5-4 8-8 10-4-2-8-5-8-10V5z',
  health: 'M9 3h6v6h6v6h-6v6H9v-6H3V9h6z',
  ammo: 'M6 3h4v6l2 3v9H4v-9l2-3zm8 2h4v5l1 2v9h-6v-9l1-2z',
  // Frame, hole, slash -- three subpaths read with the even-odd rule, so the
  // hole is empty and the slash inside it is filled.
  missing: 'M5 4h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z'
         + 'M5 6h14v12H5z'
         + 'M7 16l8.5-8.5 1.2 1.2L8.2 17.2z',
}

/** Which drawn icon stands in for a slot that has no picture of its own. */
function drawnIconFor(slot: InvSlot): DrawnIcon {
  if (slot.kind === 'ammo') return 'ammo'
  if (slot.kind === 'consumable') return CONSUMABLE_ICON[slot.id] ?? 'missing'
  // Weapons, throwables, and anything a later kind adds. There is deliberately
  // no per-weapon branch here any more -- see the note at the top of the file.
  return 'missing'
}

function Drawn({ icon, size }: { icon: DrawnIcon; size: string }) {
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
      <path d={PATHS[icon]} fill="currentColor" fillRule="evenodd" />
    </svg>
  )
}

/**
 * REAL ARTWORK IF IT IS THERE, and an admission of failure if it is not.
 *
 * Weapon PNGs go in `ui-src/public/items/<id>.png`, where `<id>` is the item id
 * from br_lib (`carbinerifle.png`, `railgun.png`, ...). Vite copies `public/`
 * verbatim into the build, so they end up at `items/<id>.png` alongside
 * index.html and resolve without any import or bundler config.
 *
 * `onError` still swaps to a drawn icon, but what it swaps to is no longer a
 * guess at the item -- it is the `missing` placeholder. Adding a PNG is still
 * the entire act of adopting it; there is no list to update in two places.
 */
function iconUrl(slot: InvSlot): string | null {
  // Ammo is artless by design, so it never asks for a file at all. CONSUMABLES
  // STILL ASK: none of the four has a PNG today and the drawn symbols are the
  // intended answer for them, but the README has always offered
  // `medkit.png`/`shield.png` as droppable, and taking that away is a change
  // nobody asked for.
  if (slot.kind === 'ammo') return null
  return `items/${slot.id}.png`
}

/** The fists slot has no item, so it is fetched from the same set by name. */
export function FistIcon({ size = '1.6rem' }: { size?: string }) {
  const [failed, setFailed] = useState(false)
  if (failed) return <Drawn icon="missing" size={size} />
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

  return <Drawn icon={drawnIconFor(slot)} size={size} />
}
