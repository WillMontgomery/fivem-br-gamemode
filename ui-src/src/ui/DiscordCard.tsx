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
 * ═══ IT ALWAYS SHOWS, UNLESS WE KNOW THEY ARE ALREADY THERE ═══
 *
 * Owner, 2026-08-31: "Let's make it always show in the help page (unless we know
 * they're in the guild)."
 *
 * THAT REPLACED A RULE, IT DID NOT JOIN ONE. Earlier the same day: "once they've
 * copied it and that screen goes away we never show it to them again that
 * session. Because they may join the discord at that moment and it's not worth
 * us writing something to listen for that." A module-level `copiedThisSession`
 * flag and a `spent` lazy initialiser implemented it, and both are GONE -- the
 * clause after "because" is the one that was answered: the server now asks
 * Discord, so a copy no longer has to stand in for having joined. Do not
 * reintroduce a copy-hides-the-card rule; it is not a smaller version of this
 * one, it is the guess this one replaces.
 *
 * WHAT SURVIVED THAT CHANGE IS EVERY LINE OF THE COPY BEHAVIOUR -- the two-step
 * clipboard, the error cue, the held timer, and the "Copied" label the owner has
 * praised twice. Only the hiding went.
 *
 * `member` IS THE ONLY THING THAT TAKES THE CARD AWAY, AND ONLY WHEN IT IS
 * `true`. bridge/types.ts has the full argument; the short version is that the
 * server sends it for a confirmed yes and for nothing else, so a server with no
 * bot token, a player whose Discord client is not running, a timeout and a rate
 * limit all leave the card exactly where it was. Testing `!member` instead would
 * be identical today and would reverse the meaning the day a `false` is sent.
 *
 * (It used a shorter verb for turning a meaning upside down until a build diff
 * caught it. Tailwind's content scan is a regex over the file's TEXT, comments
 * included, so that bare word matched a utility class and put 211 bytes of CSS
 * nothing uses into the shipped stylesheet. Like the note above the opening tag
 * below -- which cannot spell the element it is about, for the same reason with
 * a different scanner -- this one cannot spell its own subject.)
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

export default function DiscordCard() {
  // THE FIELDS, NOT THE OBJECT. Selecting them also keeps this component out of
  // the re-render that a fresh identical `{}` from a reconnect would otherwise
  // cause -- and it is why the membership answer arriving in a SECOND envelope
  // costs one re-render of this row rather than of the page around it.
  const url = useUi((s) => s.community.invite)
  const member = useUi((s) => s.community.member)
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

  // THEY ARE ALREADY IN THE DISCORD, SO THERE IS NOTHING TO INVITE THEM TO.
  //
  // `=== true`, NOT `member`. The field is absent for "not a member" AND for
  // every way of not knowing, and those are the cases that must keep the card --
  // see the header. The strict comparison is what keeps the polarity right if a
  // `false` is ever put on the wire.
  //
  // EVERY HOOK ABOVE THIS LINE RUNS FIRST AND UNCONDITIONALLY: an early return
  // placed among them would change the hook order between the render that draws
  // this and the render that does not, which matters here because the answer can
  // arrive in a second envelope while the page is already up.
  if (member === true) return null

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
