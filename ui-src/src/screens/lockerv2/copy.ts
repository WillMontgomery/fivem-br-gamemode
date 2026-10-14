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
 * "MY LOOKS" (owner, 2026-10-12/13): "I like the idea of calling them "My
 * Looks" - let's continue with that branding across the interface." So a
 * player-facing "ped" is a "look" everywhere here.
 *
 * No runtime imports, so scripts/test-lockerv2.mjs loads this file directly and
 * holds every WRITTEN line to its marker.
 */

/** The four views' headings. */
export const TITLE = {
  home: 'My Looks',           // OWNER: "calling them "My Looks""
  new: 'New',                 // OWNER: ""New" at the top"
  stock: 'Stock GTA Looks',   // OWNER: "lets call the card "Stock GTA Looks""
} as const

/** The New view's two cards, and the Custom card's dropdown. */
export const CARD = {
  custom: 'Custom',           // OWNER: "custom and "Stock GTA Peds" (custom is the default)"
  stock: 'Stock GTA Looks',   // OWNER: "actually lets call the card "Stock GTA Looks""
} as const
export const SEX_LABEL = {
  m: 'Male',                  // OWNER: "a dropdown within to select male or female"
  f: 'Female',                // OWNER: "a dropdown within to select male or female"
} as const

export const BTN = {
  done: 'Done',               // OWNER: today's Season 1 label, kept (contract owner call 2)
  back: 'Back',               // OWNER: "Clicking "back" should prompt the user about unsaved changes"
  new: 'New',                 // OWNER: ""New" at the top"
  save: 'Save',               // OWNER: "Save"
  saveAsNew: 'Save as new',   // OWNER: ""Save as new" lives in the save dialog"
  randomize: 'Randomize',     // OWNER: "they get a randomize button for the whole ped"
  undo: 'Undo',               // OWNER: "Undo/Redo"
  redo: 'Redo',               // OWNER: "Undo/Redo"
  edit: 'Edit',               // OWNER: "Edit / Rename / Delete"
  rename: 'Rename',           // OWNER: "Edit / Rename / Delete"
  delete: 'Delete',           // OWNER: "Edit / Rename / Delete"
  nextColor: 'Next color',    // OWNER: "we show a button "Next color""
  next: 'Next',               // OWNER: "a next/last button" (the icon's accessible name)
  last: 'Last',               // OWNER: "a next/last button" (the icon's accessible name)
  reset: 'Reset',             // OWNER: "a reset button" (the icon's accessible name)
  cancel: 'Cancel',           // WRITTEN (proposal for the owner)
  keepEditing: 'Keep editing', // WRITTEN (proposal for the owner)
  discard: 'Discard',         // WRITTEN (proposal for the owner)
  add: 'Add',                 // WRITTEN (proposal for the owner): a tattoo zone's Add
  addExtra: '+ Add',          // WRITTEN (proposal for the owner): the editor's extras dropdown
  remove: 'Remove',           // WRITTEN (proposal for the owner): a tattoo row's Remove, and the trash icon's accessible name
  more: 'More',               // WRITTEN (proposal for the owner): the card's "..." menu's accessible name
  fineTune: 'Fine-tune',      // WRITTEN (proposal for the owner)
} as const

export const MODAL = {
  name: 'Name your look',     // WRITTEN (proposal for the owner)
  save: 'Save look',          // WRITTEN (proposal for the owner)
  rename: 'Rename look',      // WRITTEN (proposal for the owner)
  discard: 'Discard changes?', // WRITTEN (proposal for the owner)
} as const

export const deleteTitle = (name: string): string => `Delete ${name}?` // WRITTEN (proposal for the owner)

/** The camera cluster's buttons, by their accessible names (they draw icons). */
export const CAM = {
  left: 'Rotate left',        // WRITTEN (proposal for the owner)
  right: 'Rotate right',      // WRITTEN (proposal for the owner)
  turn: 'Turn around',        // WRITTEN (proposal for the owner)
  zoomIn: 'Zoom in',          // WRITTEN (proposal for the owner)
  zoomOut: 'Zoom out',        // WRITTEN (proposal for the owner)
  reset: 'Reset view',        // WRITTEN (proposal for the owner)
} as const

/** A swatch's accessible name: the nth color of its palette. */
export const swatchLabel = (n: number): string => `Color ${n}` // WRITTEN (proposal for the owner)

/** The summary list's categories, by the `cat` Lua sends (model.ts CORE_CATS
 *  and EXTRA_CATS). */
export const CAT_LABEL: Record<string, string> = {
  face: 'Face',               // WRITTEN (proposal for the owner)
  skin: 'Skin',               // WRITTEN (proposal for the owner)
  hair: 'Hair',               // WRITTEN (proposal for the owner)
  top: 'Top',                 // WRITTEN (proposal for the owner)
  legs: 'Legs',               // WRITTEN (proposal for the owner)
  shoes: 'Shoes',             // WRITTEN (proposal for the owner)
  hat: 'Hat',                 // WRITTEN (proposal for the owner)
  glasses: 'Glasses',         // WRITTEN (proposal for the owner)
  earrings: 'Earrings',       // WRITTEN (proposal for the owner)
  mask: 'Mask',               // WRITTEN (proposal for the owner)
  vest: 'Vest',               // WRITTEN (proposal for the owner)
  bag: 'Bag',                 // WRITTEN (proposal for the owner)
  watch: 'Watch',             // WRITTEN (proposal for the owner)
  bracelet: 'Bracelet',       // WRITTEN (proposal for the owner)
  decals: 'Decals',           // WRITTEN (proposal for the owner)
  accessory: 'Accessory',     // WRITTEN (proposal for the owner)
  makeup: 'Makeup',           // WRITTEN (proposal for the owner)
  tattoos: 'Tattoos',         // WRITTEN (proposal for the owner)
}

/** The face features' groups under "Fine-tune" (model.ts FACE_GROUPS). */
export const GROUP_LABEL: Record<string, string> = {
  nose: 'Nose',               // WRITTEN (proposal for the owner)
  brows: 'Brows',             // WRITTEN (proposal for the owner)
  cheeks: 'Cheeks',           // WRITTEN (proposal for the owner)
  eyeslips: 'Eyes and lips',  // WRITTEN (proposal for the owner)
  jaw: 'Jaw',                 // WRITTEN (proposal for the owner)
  chin: 'Chin',               // WRITTEN (proposal for the owner)
  neck: 'Neck',               // WRITTEN (proposal for the owner)
}

/** The Tattoos extra's body zones, by the zone Lua sends. A tattoo's own name
 *  is never here: it is the game's text for the tattoo, sent by Lua. */
export const ZONE_LABEL: Record<string, string> = {
  head: 'Head',               // WRITTEN (proposal for the owner)
  torso: 'Torso',             // WRITTEN (proposal for the owner)
  larm: 'Left arm',           // WRITTEN (proposal for the owner)
  rarm: 'Right arm',          // WRITTEN (proposal for the owner)
  lleg: 'Left leg',           // WRITTEN (proposal for the owner)
  rleg: 'Right leg',          // WRITTEN (proposal for the owner)
}

/** A tattoo the game has no text for: the nth such in its zone, never its
 *  label key printed as a word. */
export const tattooFallback = (n: number): string => `Tattoo ${n}` // WRITTEN (proposal for the owner)

/** A zone's tattoos, each with its name, in the zone's order: the game's own,
 *  and the nameless ones numbered among themselves, so the first is "Tattoo 1"
 *  wherever it sits (#28 review: TAT_AW_000 read "Tattoo 326" at the foot of
 *  Torso). */
export function tattooLabels<T extends { name?: string }>(items: readonly T[]): [T, string][] {
  let nameless = 0
  return items.map((t): [T, string] => [t, t.name ?? tattooFallback(++nameless)])
}

/**
 * The rows, by the key Lua sends (`k`, documented on Locker2Row in
 * bridge/types.ts): the appearance JSON's own field names, `c<slot>` for a
 * component, `p<slot>` for a prop, `o<index>` for an overlay, `ff<index>` for
 * a face feature (0-based), `sk`, `e`, and `c2`/`h1` for the hair and its
 * highlight. The starting face (`shape`) has no label: it is the Face panel's
 * tiles.
 */
export const ROW_LABEL: Record<string, string> = {
  sk: 'Skin tone',            // WRITTEN (proposal for the owner)
  e: 'Eye color',             // WRITTEN (proposal for the owner)
  c2: 'Hair',                 // WRITTEN (proposal for the owner)
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
 * A row's label. An overlay's opacity is named from it: `o2op` is "Eyebrows
 * opacity" (contract: "<row> opacity"). A key this table does not know has no
 * label at all -- the page never prints Lua's key as if it were a word -- and
 * is reported once.
 */
export function rowLabel(k: string): string | null {
  const own = ROW_LABEL[k]
  if (own !== undefined) return own
  const m = /^(o\d+)op$/.exec(k)
  const base = m?.[1] !== undefined ? ROW_LABEL[m[1]] : undefined
  if (m && base !== undefined) {
    return `${base} opacity` // WRITTEN (proposal for the owner)
  }
  return null
}
