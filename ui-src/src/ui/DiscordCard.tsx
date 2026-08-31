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
 * WHICH IS WHY THE ADDRESS IS PRINTED ON IT (owner, 2026-08-30, choosing this
 * over a title-only card, and again on 2026-08-31 when it shrank: "Keep the
 * address visible"). The clipboard is a thing that can fail -- see the click
 * handler -- and when it does, a readable address is the only thing left that a
 * player can act on.
 *
 * ═══ IT WAS A PLATE IN TWO PLACES AND IT IS NOW A LINE IN ONE ═══
 *
 * SHIPPED 2026-08-30 as a full-width two-line plate under the pause menu's
 * Resume button and under the lobby's menu row. The owner played it and cut it
 * on 2026-08-31: "the card in the pause menu is HUGE. we don't need that. Find
 * a better place for it. Perhaps on the Help page only."
 *
 * So it is one row of screens/Help.tsx now, and nothing else imports it. It
 * sits beside that page's Copy link button because that button is the same
 * gesture aimed at the other address, and it is deliberately built to the SIZE
 * of that button -- title, address and the reserved label on one line, at the
 * button's own 0.72rem -- so it reads as one more line of the page rather than
 * as an object on it. Two lines and a 1.05rem title were what made it a hero.
 *
 * WHAT SURVIVED THE CUT UNTOUCHED IS THE "Copied" LABEL, on his instruction in
 * the same message: "Good thing is the 'copied' text looks really good." Its
 * size, colour, reserved width, fade and 2400ms hold below are byte-for-byte
 * what he saw. Do not tidy them.
 *
 * ═══ ONE SUCCESSFUL COPY AND IT IS DONE FOR THE SESSION ═══
 *
 * Owner, 2026-08-31: "once they've copied it and that screen goes away (like
 * the lobby) we never show it to them again that session. Because they may join
 * the discord at that moment and it's not worth us writing something to listen
 * for that."
 *
 * `spent` below is a module-level flag read ONCE, in a lazy initialiser, so the
 * decision is taken at mount and cannot change under a player who is looking at
 * the thing. That is what makes "and that screen goes away" literal: the label
 * still shows, the address stays readable while they are on the page, and it is
 * the NEXT open of Help that finds it gone.
 *
 * NOT localStorage, AND NOT THE SAVED PROFILE. "That session" is what he asked
 * for and it is also the right ceiling: a permanent hide would silently stop
 * inviting somebody who reinstalls, clears CEF's cache into a different state
 * than their profile, or simply changes their mind next week. A module-level
 * `let` dies with the CEF page, which is the client session, which is the
 * question.
 *
 * ONLY A SUCCESS COUNTS. The flag is set on the same line that decides the
 * label may appear -- past the `if (!ok) return` -- because a card that hid
 * itself after a copy that never reached the clipboard would have taken the
 * address away at the exact moment it became the only thing left to read.
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
 * The plate recipe is the Help page's other plates', and the accent is spent on
 * the one word that reports a result. Cyan is the one loud object on a screen
 * -- ui/Btn.tsx states the rule -- and on Help it is already spent on Back. An
 * invitation is not competing with the way out.
 */

/**
 * Whether a copy has landed in this client session.
 *
 * MODULE SCOPE ON PURPOSE, not the zustand store. Nothing renders off this --
 * it is read exactly once per mount and never during an update -- so putting it
 * in the store would buy a subscription that can only cause re-renders nobody
 * asked for. It lives and dies with the CEF page, which is the definition of
 * "session" here.
 */
let copiedThisSession = false

export default function DiscordCard() {
  // THE STRING, NOT THE OBJECT. Selecting the field also keeps this component
  // out of the re-render that a fresh identical `{}` from a reconnect would
  // otherwise cause.
  const url = useUi((s) => s.community.invite)
  const [copied, setCopied] = useState(false)

  // READ ON MOUNT AND NEVER AGAIN, which is the whole of "and that screen goes
  // away". A lazy initialiser, not a plain read: `useState(copiedThisSession)`
  // would evaluate the flag on every render and React would keep the first
  // value anyway, so it would look wrong AND behave right, which is worse.
  const [spent] = useState(() => copiedThisSession)

  // THE TIMER IS HELD, CLEARED BEFORE RESCHEDULING, AND CLEARED ON UNMOUNT.
  // Help.tsx did none of that and a second press there blanks the label early:
  // the first timeout is still armed and fires 2.4s after the FIRST press,
  // hiding a label the second press had just put up. Closing the menu mid-hold
  // would additionally set state on an unmounted component.
  const timer = useRef<number | null>(null)
  useEffect(() => () => {
    if (timer.current !== null) window.clearTimeout(timer.current)
  }, [])

  // ALREADY TAKEN, SO NOTHING IS DRAWN. Every hook above this line runs first
  // and unconditionally: an early return placed among them would change the
  // hook order between the mount that shows this and the mount that does not.
  if (spent) return null

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
      //
      // AND THE SESSION FLAG IS NOT SET HERE. A failed copy leaves this exactly
      // as it was, still on the page and still showing the address, because a
      // failed copy is the case where the address matters most.
      play('ui.error')
      return
    }

    play('ui.select')
    // SET BEFORE THE LABEL, AND IT DOES NOT AFFECT THIS MOUNT. `spent` was
    // taken at mount, so this row stays put and finishes its hold; the next
    // open of Help is the one that finds nothing here.
    copiedThisSession = true
    if (timer.current !== null) window.clearTimeout(timer.current)
    setCopied(true)
    // 2400ms, matching Help.tsx's hold for the same action.
    timer.current = window.setTimeout(() => {
      setCopied(false)
      timer.current = null
    }, 2400)
  }

  // Hand-rolled rather than ui/Btn, because Btn is a single label in a pill and
  // this is three pieces of text with different jobs. The class list is the
  // shared vocabulary either way: shape and bevel from .plate, press travel,
  // hover brighten and the :focus-visible ring from .btn -- which check-ui R3
  // requires of any hand-rolled button element, and which is also the whole of
  // keyboard reachability here, since this project has no focus-navigation
  // system and native DOM order is it.
  //
  // px-3 py-1 AGAINST THE Btn `sm` BESIDE IT, which is px-3 py-1.5 around a
  // 0.72rem label. The half-step of padding is given back to the address, which
  // is set a size larger than everything else in the row; the two controls come
  // out the same height, which is the point.
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
      className="plate btn shrink-0 text-left flex items-center gap-2.5 px-3 py-1"
      style={{
        ['--edgec' as string]: 'rgba(255,255,255,0.16)',
        ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
        ['--cut-max' as string]: '0.5rem',
      }}
    >
      {/* `.ts` AND AN EXPLICIT --fs, never `tscale`, which multiplies the
          PARENT's size and so either loses to a later rule or discards the
          declared one. See the note on .ts in index.css. 0.72rem is the Btn
          `sm` label's size, which is what this is a sibling of. */}
      <span
        className="font-display uppercase tracking-[0.08em] ts shrink-0"
        style={{ ['--fs' as string]: '0.72rem' }}
      >
        Join our Discord!
      </span>
      {/* THE ADDRESS ITSELF, WRAPPED RATHER THAN TRUNCATED. An ellipsis would
          defeat the only reason it is printed: this is what a player reads and
          types by hand when the copy does not land, and half an invite code is
          worth nothing. `break-all` because a URL has no spaces to wrap at.
          It is the one thing in this row set above the row's own size, because
          it is the only thing here anybody has to READ rather than recognise.
          Help's column is 68rem and an invite is thirty characters, so this
          does not wrap today -- it is here so that the day something longer
          arrives the row grows instead of overflowing, and the header row it
          lives in is `flex-wrap` so the growth lands on a new line. */}
      <span
        className="body-text break-all"
        style={{ ['--fs' as string]: '0.8rem' }}
      >
        {invite}
      </span>
      {/* ALWAYS RENDERED, TOGGLED BY OPACITY. Mounting it on copy would widen
          the row at the instant of the press and shove the address sideways;
          reserving the width from first paint makes the zero-reflow guarantee
          free, which is the same doctrine as the exits card's confirm row and
          the XP readout.

          NOT a `title=` tooltip: offscreen CEF never paints native tooltips, so
          ui/Btn.tsx's own `title` prop is dead in game. NOT absolutely
          positioned either: .plate carries a clip-path that would cut it off.

          UNCHANGED FROM THE CARD THIS REPLACES, deliberately -- see the note at
          the top of this file. */}
      <span
        className="font-display uppercase tracking-[0.08em] ts shrink-0"
        style={{
          ['--fs' as string]: '0.72rem',
          color: 'var(--color-royale-accent)',
          opacity: copied ? 1 : 0,
          transition: 'opacity 200ms var(--ease-out)',
        }}
      >
        Copied
      </span>
    </button>
  )
}
