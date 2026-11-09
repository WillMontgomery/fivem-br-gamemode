import { useState } from 'react'
import { useUi } from '../../store'
import { PAGE_PRESET, PAGE_STEP, PresenceScope } from '../../ui/broadcast'
import InventoryPageV2, { PAGE_QUICK } from './Page'

/** No native drag of the page's pictures (inventory.css says why). */
const noNativeDrag = (e: { preventDefault(): void }) => e.preventDefault()

/**
 * THE TAB PAGE'S PLACE (#431): what App draws for the inventory piece of UI v2
 * where it draws today's `{focus === 'inventory' && hudUp && <InventoryPanel />}`,
 * the Broadcast page (./Page.tsx) in the box that centers it and in the page's
 * own scope.
 *
 *   the box    fixed over the whole screen, pointer events on the page alone:
 *              the rest of the screen stays playable, the reason this screen
 *              holds keep-input focus. It carries bc-kit, the class the kit's
 *              tokens are declared on, and stays mounted while the page comes
 *              and goes, so the page can play its way out. The page inside it
 *              is a presence, never a fixed box.
 *   the scope  wanted while the HUD is up (`up`, App's hudUp) and Lua's focus
 *              is the inventory, as today's line; on the kit's page preset,
 *              broadcast at twice the speed (the owner, 2026-11-04: "make the
 *              inventory page appear and disappear 2x the speed"), with its
 *              stagger named too (a scope that names none takes the one above
 *              it), unless the pause menu took the page's place (usePageExit).
 */
export default function InventoryPageSlot({ up }: { up: boolean }) {
  const focus = useUi((s) => s.focus)
  const exit = usePageExit(focus)
  return (
    <div className="bc-kit binv-pagebox" onDragStart={noNativeDrag}>
      <PresenceScope want={up && focus === 'inventory'} step={PAGE_STEP} preset={exit ?? PAGE_PRESET}>
        <InventoryPageV2 />
      </PresenceScope>
    </div>
  )
}

/**
 * THE PAGE'S WAY OUT, BY WHAT TOOK ITS FOCUS. The pause menu taking the focus
 * of an open page sends the page out on the quick hide's timing (PAGE_QUICK,
 * 150 ms), and that holds until the page is next opened, so a pause that
 * closes again at once never turns the page round mid-fade. Anything else that
 * ends it (TAB, Esc, a right-click, the HUD going) is its own way off air. In
 * game Esc never opens our pause menu over the page (br_core keybinds.lua
 * holds Escape for the screen that has it), so only another push of the pause
 * focus takes this way. Derived in render from the focus it last saw.
 */
function usePageExit(focus: string): string | undefined {
  const [seen, setSeen] = useState<{ focus: string; preset: string | undefined }>(() => ({ focus, preset: undefined }))
  if (seen.focus === focus) return seen.preset
  const preset = focus === 'inventory' ? undefined
    : focus === 'pause' && seen.focus === 'inventory' ? PAGE_QUICK
      : seen.preset
  setSeen({ focus, preset })
  return preset
}
