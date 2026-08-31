import { useEffect, useRef, useState } from 'react'
import { useUi } from '../store'
import { play } from '../audio/cues'

/**
 * The invitation to our Discord (owner, 2026-08-30).
 *
 * IT COPIES; IT CANNOT OPEN. The game client has no native for launching a
 * browser and CEF's window.open goes nowhere useful from a nui:// page --
 * screens/Help.tsx records the same finding beside the same decision. So the
 * honest version of "go here" is to hand over the address in one press and let
 * the player paste it wherever they like.
 *
 * WHICH IS WHY THE ADDRESS IS PRINTED ON THE CARD (owner, 2026-08-30, choosing
 * this over a title-only card). The clipboard is a thing that can fail -- see
 * the click handler -- and when it does, a readable address is the only thing
 * left that a player can act on. The card is a line taller for it, which is the
 * whole cost.
 *
 * ═══ THE PAYLOAD ARRIVING IS NOT THE CONDITION ═══
 *
 * Lua sends `{}` on br:ready when this deployment publishes no invite -- on
 * purpose, so a card already on screen comes down when an operator clears the
 * convar and restarts. `{}` is truthy. A component that asked whether
 * `s.community` existed would draw an empty card on every unconfigured server,
 * which is the exact shape of "the card is broken" bug reports. The guard below
 * tests the STRING, and it also catches the empty-table-as-array that Lua's JSON
 * encoding can produce.
 *
 * ═══ QUIET, NOT CYAN ═══
 *
 * The plate recipe is the exits card's (screens/PauseMenu.tsx), not the mode
 * tile's. Cyan is the one loud object on a screen -- ui/Btn.tsx states the rule
 * -- and on the pause menu it is already spent on Resume. An invitation is not
 * competing with the way out.
 */
export default function DiscordCard() {
  // THE STRING, NOT THE OBJECT. Selecting the field also keeps this component
  // out of the re-render that a fresh identical `{}` from a reconnect would
  // otherwise cause.
  const url = useUi((s) => s.community.invite)
  const [copied, setCopied] = useState(false)

  // THE TIMER IS HELD, CLEARED BEFORE RESCHEDULING, AND CLEARED ON UNMOUNT.
  // Help.tsx did none of that and a second press there blanks the label early:
  // the first timeout is still armed and fires 2.4s after the FIRST press,
  // hiding a label the second press had just put up. Closing the menu mid-hold
  // would additionally set state on an unmounted component.
  const timer = useRef<number | null>(null)
  useEffect(() => () => {
    if (timer.current !== null) window.clearTimeout(timer.current)
  }, [])

  // NO ADDRESS, NO CARD. Not a disabled card, not an empty one -- the standing
  // rule on this screen, the same treatment the Admin tab and the spectate exit
  // get. A control that has nothing to do is not drawn.
  if (typeof url !== 'string' || url.trim() === '') return null
  const invite = url.trim()

  const copy = async () => {
    // WHERE THE FOCUS WAS. The fallback below selects a textarea, which takes
    // focus off whatever the player was on -- and this project has no
    // focus-navigation system of its own, so the native DOM order is the whole
    // of keyboard use here and losing a position in it is not recoverable.
    const was = document.activeElement as HTMLElement | null
    let ok = false

    try {
      // TRIED FIRST AND EXPECTED TO REJECT. NUI is served over https so this is
      // a secure context and the API exists, but CEF Alloy grants no
      // clipboard-write permission and asking for it has been an open Cfx.re
      // request since 2021. It costs one rejected promise, and it is what makes
      // this card come right on its own the day that changes.
      await navigator.clipboard.writeText(invite)
      ok = true
    } catch {
      // THE PATH THAT ACTUALLY RUNS. Deprecated everywhere and alive here,
      // which is exactly the situation execCommand is kept around for -- and it
      // answers with a BOOLEAN, synchronously, which is the only reason this
      // card can tell the truth about whether anything was copied.
      const el = document.createElement('textarea')
      el.value = invite
      // FIXED AND TRANSPARENT, NOT `display: none`. An unrendered element
      // cannot hold a selection at all, and an unpositioned one can scroll the
      // document -- which matters because the pause menu's root is the thing
      // that scrolls.
      el.style.position = 'fixed'
      el.style.opacity = '0'
      document.body.appendChild(el)
      el.select()
      try { ok = document.execCommand('copy') } catch { ok = false }
      el.remove()
      was?.focus?.()
    }

    if (!ok) {
      // THE ERROR CUE INSTEAD OF THE PRESS CUE, NEVER AFTER IT -- ui/Btn.tsx's
      // refusal path does the same. And nothing is said: no wording exists for
      // this and none is invented here. The address is on the card, which is
      // why it is on the card.
      play('ui.error')
      return
    }

    play('ui.select')
    if (timer.current !== null) window.clearTimeout(timer.current)
    setCopied(true)
    // 2400ms, matching Help.tsx's hold for the same action.
    timer.current = window.setTimeout(() => {
      setCopied(false)
      timer.current = null
    }, 2400)
  }

  // Hand-rolled rather than ui/Btn, because Btn is a label in a pill and this is
  // a plate with two lines in it. The class list is the shared vocabulary
  // either way: shape and bevel from .plate, press travel, hover brighten and
  // the :focus-visible ring from .btn -- which check-ui R3 requires of any
  // hand-rolled button element, and which is also the whole of keyboard
  // reachability here, since this project has no focus-navigation system and
  // native DOM order is it.
  //
  // THIS NOTE IS OUTSIDE THE TAG ON PURPOSE, AND NAMES NO TAG. R3 tests the
  // opening tag's TEXT for the token, comments included, so an explanation
  // written between the attributes satisfies the rule by talking about it --
  // which is what this comment did until a mutation test caught it. Written out
  // here it must also avoid spelling the element, because the rule finds its
  // subjects by scanning for that spelling and would audit the sentence.
  return (
    <button
      type="button"
      onPointerEnter={() => play('ui.hover')}
      onClick={copy}
      className="plate btn w-full text-left flex items-center gap-6 px-4 py-3.5"
      style={{
        ['--edgec' as string]: 'rgba(255,255,255,0.16)',
        ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
        ['--cut-max' as string]: '0.6rem',
      }}
    >
      <div className="flex-1 min-w-0">
        {/* `.ts` AND AN EXPLICIT --fs, never `tscale`, which multiplies the
            PARENT's size and so either loses to a later rule or discards the
            declared one. See the note on .ts in index.css. 1.05rem is the exits
            card's row title, which is what this is a sibling of. */}
        <div
          className="font-display uppercase tracking-[0.08em] ts"
          style={{ ['--fs' as string]: '1.05rem' }}
        >
          Join our Discord!
        </div>
        {/* THE ADDRESS ITSELF, WRAPPED RATHER THAN TRUNCATED. An ellipsis would
            defeat the only reason it is printed: this is what a player reads and
            types by hand when the copy does not land, and half an invite code is
            worth nothing. `break-all` because a URL has no spaces to wrap at.
            The pause menu's column is 68rem and an invite is thirty characters,
            so this does not wrap today -- it is here so that the day something
            longer arrives the card grows instead of overflowing. */}
        <div
          className="body-text mt-0.5 break-all"
          style={{ ['--fs' as string]: '0.8rem' }}
        >
          {invite}
        </div>
      </div>
      {/* ALWAYS RENDERED, TOGGLED BY OPACITY. Mounting it on copy would widen
          the card at the instant of the press and shove the address sideways;
          reserving the width from first paint makes the zero-reflow guarantee
          free, which is the same doctrine as the exits card's confirm row and
          the XP readout.

          NOT a `title=` tooltip: offscreen CEF never paints native tooltips, so
          ui/Btn.tsx's own `title` prop is dead in game. NOT absolutely
          positioned either: .plate carries a clip-path that would cut it off. */}
      <div
        className="font-display uppercase tracking-[0.08em] ts shrink-0"
        style={{
          ['--fs' as string]: '0.72rem',
          color: 'var(--color-royale-accent)',
          opacity: copied ? 1 : 0,
          transition: 'opacity 200ms var(--ease-out)',
        }}
      >
        Copied
      </div>
    </button>
  )
}
