/**
 * PUT TEXT ON THE CLIPBOARD, AND SAY WHETHER IT GOT THERE (#413).
 *
 * The one copy routine in br_ui: Help's "Copy link" and the Discord card both
 * call it, and check-cef holds `execCommand` to a focused field so a second
 * copy of this cannot drift back to the old form.
 *
 *   1. navigator.clipboard. NUI is served over https, so the API exists, but
 *      CEF Alloy grants no clipboard-write permission and asking for it has
 *      been an open Cfx.re request since 2021. Expected to reject. It is raced
 *      against WAIT_MS because a permission request nobody answers would leave
 *      the promise pending, and a button that waits forever says nothing.
 *   2. document.execCommand('copy') on a hidden textarea: deprecated
 *      everywhere, alive in CEF, and it answers with a boolean, which is how
 *      both buttons can tell the truth about whether anything was copied.
 *
 * THE FIELD IS FOCUSED BEFORE IT IS SELECTED. CEF 103 copied a selection in a
 * field that never had focus; CEF 144 copies only from a focused element and
 * otherwise returns false with nothing copied. Focusing first is correct on
 * both. `preventScroll` because the pause menu's root is the thing that
 * scrolls, and the focus goes back where it was afterwards: this project has
 * no focus system of its own, so the DOM order is the whole of keyboard use
 * and losing a place in it is not recoverable.
 *
 * FIXED AND TRANSPARENT, NOT `display: none`: an unrendered element cannot
 * hold a selection, and an unpositioned one can scroll the document.
 */
const WAIT_MS = 500

export async function copyText(text: string): Promise<boolean> {
  try {
    const wrote = await Promise.race([
      navigator.clipboard.writeText(text).then(() => true),
      new Promise<false>((resolve) => { window.setTimeout(() => resolve(false), WAIT_MS) }),
    ])
    if (wrote) return true
  } catch { /* the expected path in CEF: fall through */ }

  const was = document.activeElement instanceof HTMLElement ? document.activeElement : null
  const el = document.createElement('textarea')
  el.value = text
  el.style.cssText = 'position:fixed;top:0;left:0;opacity:0;pointer-events:none'
  document.body.appendChild(el)
  let ok = false
  try {
    el.focus({ preventScroll: true })
    el.select()
    ok = document.execCommand('copy')
  } catch {
    ok = false
  }
  el.remove()
  was?.focus({ preventScroll: true })
  return ok
}
