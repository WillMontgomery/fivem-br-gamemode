/**
 * EVERY WORD LOCKER V2 PUTS ON SCREEN (#28), and nowhere else.
 *
 * Two kinds, marked line by line:
 *
 *   OWNER   his words from #28, verbatim or as the label he named.
 *   WRITTEN a proposal for the owner, from the contract's copy list. Each one
 *           carries `// WRITTEN (proposal for the owner)` and is listed in the
 *           build's report so he meets every one before a player does.
 *
 * No runtime imports, so scripts/test-lockerv2.mjs loads this file directly and
 * holds every WRITTEN line to its marker.
 */

import type { Tab } from './model'

export const TAB_LABEL: Record<Tab, string> = {
  peds: 'My peds',             // OWNER: "an additional tab called "My peds""
  stock: 'Stock peds',         // OWNER: "Stock peds"
  male: 'Custom (male)',       // OWNER: "Custom (male)"
  female: 'Custom (female)',   // OWNER: "Custom (female)"
}

/** The hover card on a tab locked by unsaved changes. */
export const LOCKED_TAB = 'Save or reset your changes first.' // WRITTEN (proposal for the owner)

export const BTN = {
  done: 'Done',               // OWNER: today's Season 1 label, kept (contract owner call 2)
  save: 'Save',               // OWNER: "Save"
  reset: 'Reset',             // OWNER: "Reset"
  edit: 'Edit',               // OWNER: "edit"
  rename: 'Rename',           // OWNER: "rename"
  create: 'Create',           // OWNER: "create"
  delete: 'Delete',           // OWNER: "delete"
  nextColor: 'Next color',    // OWNER: "we show a button "Next color""
  next: 'Next',               // OWNER: "a next/last button" (the icon's accessible name)
  last: 'Last',               // OWNER: "a next/last button" (the icon's accessible name)
  createNew: 'Create new',    // OWNER: "allows them to create new or replace existing"
  replaceExisting: 'Replace existing', // OWNER: "allows them to create new or replace existing"
  cancel: 'Cancel',           // WRITTEN (proposal for the owner)
  replace: 'Replace',         // WRITTEN (proposal for the owner)
  keepEditing: 'Keep editing', // WRITTEN (proposal for the owner)
  discard: 'Discard',         // WRITTEN (proposal for the owner)
  saveAsNew: 'Save as new',   // WRITTEN (proposal for the owner)
} as const

/** "Update <name>", the split Save's menu line while editing a saved ped. */
export const updateLabel = (name: string): string => `Update ${name}` // WRITTEN (proposal for the owner)

export const MODAL = {
  name: 'Name your ped',      // WRITTEN (proposal for the owner)
  rename: 'Rename ped',       // WRITTEN (proposal for the owner)
  discard: 'Discard changes?', // WRITTEN (proposal for the owner)
} as const

export const replaceTitle = (name: string): string => `Replace ${name}?` // WRITTEN (proposal for the owner)
export const deleteTitle = (name: string): string => `Delete ${name}?` // WRITTEN (proposal for the owner)

/** The anchor navigation's categories (contract section 2). */
export const CAT_LABEL: Record<string, string> = {
  face: 'Face',               // WRITTEN (proposal for the owner)
  hair: 'Hair',               // WRITTEN (proposal for the owner)
  makeup: 'Makeup',           // WRITTEN (proposal for the owner)
  skin: 'Skin',               // WRITTEN (proposal for the owner)
  body: 'Body',               // WRITTEN (proposal for the owner)
  headwear: 'Headwear',       // WRITTEN (proposal for the owner)
  tops: 'Tops',               // WRITTEN (proposal for the owner)
  vests: 'Vests',             // WRITTEN (proposal for the owner)
  accessories: 'Accessories', // WRITTEN (proposal for the owner)
  bags: 'Bags',               // WRITTEN (proposal for the owner)
  legs: 'Legs',               // WRITTEN (proposal for the owner)
  shoes: 'Shoes',             // WRITTEN (proposal for the owner)
}

/**
 * The rows, by the key Lua sends (`k`, documented on Locker2Row in
 * bridge/types.ts): the appearance JSON's own field names, `c<slot>` for a
 * component, `p<slot>` for a prop, `o<index>` for an overlay, `ff<index>` for
 * a face feature (0-based), `sk`, `e`, and `h0`/`h1` for the hair's two colors.
 */
export const ROW_LABEL: Record<string, string> = {
  sk: 'Skin tone',            // WRITTEN (proposal for the owner)
  e: 'Eye color',             // WRITTEN (proposal for the owner)
  c2: 'Hair',                 // WRITTEN (proposal for the owner)
  h0: 'Hair color',           // WRITTEN (proposal for the owner)
  h1: 'Highlight',            // WRITTEN (proposal for the owner)
  o2: 'Eyebrows',             // WRITTEN (proposal for the owner)
  o1: 'Facial hair',          // WRITTEN (proposal for the owner)
  o4: 'Makeup',               // WRITTEN (proposal for the owner)
  o5: 'Blush',                // WRITTEN (proposal for the owner)
  o8: 'Lipstick',             // WRITTEN (proposal for the owner)
  o0: 'Blemishes',            // WRITTEN (proposal for the owner)
  o3: 'Aging',                // WRITTEN (proposal for the owner)
  o6: 'Complexion',           // WRITTEN (proposal for the owner)
  o7: 'Sun damage',           // WRITTEN (proposal for the owner)
  o9: 'Moles and freckles',   // WRITTEN (proposal for the owner)
  o11: 'Body blemishes',      // WRITTEN (proposal for the owner)
  o12: 'More body blemishes', // WRITTEN (proposal for the owner)
  o10: 'Chest hair',          // WRITTEN (proposal for the owner)
  p0: 'Hat',                  // WRITTEN (proposal for the owner)
  p1: 'Glasses',              // WRITTEN (proposal for the owner)
  p2: 'Earrings',             // WRITTEN (proposal for the owner)
  c1: 'Mask',                 // WRITTEN (proposal for the owner)
  c11: 'Top',                 // WRITTEN (proposal for the owner)
  c8: 'Undershirt',           // WRITTEN (proposal for the owner)
  c3: 'Arms',                 // WRITTEN (proposal for the owner)
  c9: 'Vest',                 // WRITTEN (proposal for the owner)
  c10: 'Decals',              // WRITTEN (proposal for the owner)
  c7: 'Accessory',            // WRITTEN (proposal for the owner)
  p6: 'Watch',                // WRITTEN (proposal for the owner)
  p7: 'Bracelet',             // WRITTEN (proposal for the owner)
  c5: 'Bag',                  // WRITTEN (proposal for the owner)
  c4: 'Legs',                 // WRITTEN (proposal for the owner)
  c6: 'Shoes',                // WRITTEN (proposal for the owner)
  ff0: 'Nose width',          // WRITTEN (proposal for the owner)
  ff1: 'Nose height',         // WRITTEN (proposal for the owner)
  ff2: 'Nose length',         // WRITTEN (proposal for the owner)
  ff3: 'Nose bridge',         // WRITTEN (proposal for the owner)
  ff4: 'Nose tip',            // WRITTEN (proposal for the owner)
  ff5: 'Nose twist',          // WRITTEN (proposal for the owner)
  ff6: 'Brow height',         // WRITTEN (proposal for the owner)
  ff7: 'Brow depth',          // WRITTEN (proposal for the owner)
  ff8: 'Cheekbone height',    // WRITTEN (proposal for the owner)
  ff9: 'Cheekbone width',     // WRITTEN (proposal for the owner)
  ff10: 'Cheek width',        // WRITTEN (proposal for the owner)
  ff11: 'Eye opening',        // WRITTEN (proposal for the owner)
  ff12: 'Lip thickness',      // WRITTEN (proposal for the owner)
  ff13: 'Jaw width',          // WRITTEN (proposal for the owner)
  ff14: 'Jaw length',         // WRITTEN (proposal for the owner)
  ff15: 'Chin height',        // WRITTEN (proposal for the owner)
  ff16: 'Chin length',        // WRITTEN (proposal for the owner)
  ff17: 'Chin width',         // WRITTEN (proposal for the owner)
  ff18: 'Chin dimple',        // WRITTEN (proposal for the owner)
  ff19: 'Neck thickness',     // WRITTEN (proposal for the owner)
}

/**
 * A row's label. An overlay's two companions are named from it: `o2op` is
 * "Eyebrows opacity", `o2col` "Eyebrows color" (contract: "<row> opacity" and
 * "<row> color"). A key this table does not know has no label at all -- the
 * page never prints Lua's key as if it were a word -- and is reported once.
 */
export function rowLabel(k: string): string | null {
  const own = ROW_LABEL[k]
  if (own !== undefined) return own
  const m = /^(o\d+)(op|col)$/.exec(k)
  const base = m?.[1] !== undefined ? ROW_LABEL[m[1]] : undefined
  if (m && base !== undefined) {
    return m[2] === 'op'
      ? `${base} opacity` // WRITTEN (proposal for the owner)
      : `${base} color`   // WRITTEN (proposal for the owner)
  }
  return null
}
