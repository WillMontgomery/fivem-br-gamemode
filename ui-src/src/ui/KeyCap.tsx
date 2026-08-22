import type { ReactNode } from 'react'
import { useUi } from '../store'

/**
 * A KEY, DRAWN AS A KEY.
 *
 * Owner, 2026-08-22: "we should make our own glyphs for keys. For example,
 * this message looks too bland and hard coded: 'Voice chat is set to nearby.
 * Hold N to speak. You can change your preference and keybinds in Settings.'"
 *
 * THE COMPLAINT IS NOT THE WORDING -- that sentence is his, it is composed in
 * Lua (br_core/client/voice.lua, BR.Voice.noticeFor) and not one word of it has
 * moved. It is that the N in the middle of it is a letter of prose. It sits in
 * Barlow, at the sentence's weight, between two spaces, and reads as somebody
 * having typed the letter N -- which, until this file existed, is exactly what
 * had happened everywhere except the spectate hint.
 *
 * ═══ THIS IS NOT A NEW TREATMENT, AND THAT IS THE POINT ═══
 *
 * The markup below is hud/SpectateHint.tsx's key badge, moved. That badge was
 * already the right answer -- "the same hardware treatment the Keybinds screen
 * gives the row a player would go and change", deliberately not a button, not
 * focusable, no click handler -- and the only thing wrong with it was that it
 * was the only one. #209 asks for the surfaces to "end up sharing one treatment
 * rather than growing a second", so the badge moved here and the hint now calls
 * it. Nothing about how it draws changed; the pixels are the ones that shipped.
 *
 * `.plate` and `font-display` are the Keybinds screen's own capture control
 * minus its interactivity, so a key drawn in a sentence, a key drawn under
 * SPECTATING, and the key you press to rebind it are three views of one object.
 *
 * ═══ THE KEY COMES FROM THE BINDING, ALWAYS ═══
 *
 * Resolved out of `keybinds` BY COMMAND NAME -- the same rows the rebinder
 * screen draws. Lua pushes that list at start and again on every rebind
 * (br_core/client/keybinds.lua, BR.Keys.push), so this is a live subscription:
 * move push-to-talk off N and every glyph naming it redraws with no further
 * plumbing. NOTHING HERE OR UPSTREAM SPELLS A LETTER. That is the constraint
 * the spectate hint was already built to and it is now the only way to draw a
 * key at all.
 *
 * AN UNBOUND ACTION DRAWS A DASH rather than a blank plate or a stale letter.
 * `key` is '' for a row nothing is bound to -- a state a player reaches by
 * rebinding something else onto the key, since keybinds.lua resolves a conflict
 * in favour of the new binding and leaves the loser unbound. An empty plate
 * reads as the interface having failed to load; a dash says the key is gone,
 * which is true and is recoverable from the Controls screen. It is the spectate
 * hint's own answer, kept.
 *
 * A COMMAND THIS CLIENT HAS NEVER HEARD OF DRAWS THE SAME DASH, and it is
 * reached by one more route worth naming: the list is EMPTY until Lua's first
 * push. A glyph is therefore honest about knowing nothing rather than guessing,
 * and it fills itself in the moment the push lands.
 */
export function KeyCap({ command, fs = '0.8rem' }: {
  /** The RegisterCommand name, e.g. 'brptt'. Never a key label. */
  command: string
  /**
   * The plate's own size. Scales with the player's text slider from there.
   *
   * `.ts` WITH AN EXPLICIT --fs, NEVER BARE `.tscale`: this element declares
   * its own size and `.tscale` multiplies 1em -- the PARENT's -- throwing the
   * declared value away. That is #159, and index.css records the pair biting.
   *
   * AND IT DOES SCALE, which is the one place this differs from the HUD's
   * numerals. A numeral in a pill is a fixed plate because the pill cannot
   * grow; a key inside a sentence has to grow WITH the sentence or the
   * player's largest text setting leaves a tiny cap stranded mid-line. The
   * spectate hint's badge has always scaled, and this is that badge.
   */
  fs?: string
}) {
  // A STRING OUT OF THE STORE, NOT THE ROW. Returning the matched object would
  // hand zustand a fresh reference on every push and re-render every glyph in
  // the interface whenever any binding anywhere changed.
  const key = useUi((s) => s.keybinds.find((k) => k.command === command)?.key) || ''

  return (
    <span
      className="plate ts font-display text-center"
      style={{
        ['--fs' as string]: fs,
        ['--edgec' as string]: key
          ? 'rgba(255,255,255,0.22)'
          : 'rgba(255,255,255,0.12)',
        ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
        ['--cut-max' as string]: '0.3rem',
        color: key ? '#ffffff' : 'rgba(255,255,255,0.3)',
        minWidth: '2.6rem',
        padding: '0.15rem 0.5rem',
        lineHeight: 1.4,
        // ═══ THE THREE PROPERTIES THAT MAKE IT WORK INSIDE A SENTENCE ═══
        //
        // inline-block, AND IT IS LOAD-BEARING RATHER THAN TIDINESS. On a bare
        // inline box `min-width` does not apply at all and vertical padding
        // does not affect line height -- so a one-letter cap would collapse to
        // the width of the letter and its top edge would overlap the line
        // above. In the spectate hint the badge is a FLEX ITEM, which the
        // browser blockifies for free, which is why the bug was not visible
        // there and why the property has to be stated now that the same badge
        // has to survive being dropped into prose.
        display: 'inline-block',
        // Middle, not baseline: the cap's own text sits inside padding, so on
        // a shared baseline the plate hangs below the line it is in.
        verticalAlign: 'middle',
        // A LONG LABEL WIDENS, IT NEVER WRAPS. `Page Down`, `Backspace` and
        // `Num 5` all reach here from BR.Keys.vkName, and a cap broken across
        // two lines is not a key. The plate grows past its 2.6rem floor and the
        // sentence reflows around it, which is what a wide key should do.
        whiteSpace: 'nowrap',
        // ═══ NO TRANSITION, AND IT IS A CORRECTNESS FIX RATHER THAN TASTE ═══
        //
        // `.plate` transitions clip-path, transform and border-color, all three
        // for its FOCUS BEVEL -- a plate grows and opens its corners when it
        // takes focus. A key cap is never focusable and has no bevel to animate,
        // so none of that applies here.
        //
        // The border-color leg actively breaks this component. `.plate` sets
        // `border: 1px solid var(--edgec)`, a shorthand whose value is a
        // variable, and MEASURED in the harness: with the transition active,
        // changing --edgec on a live element does not repaint the border at
        // all -- it keeps whatever it first resolved to. Reproduced on a bare
        // `<span class="plate">` with no React anywhere near it, and it goes
        // away the instant the transition does.
        //
        // What that costs is exactly the thing #209 requires: a glyph on screen
        // when the player rebinds -- the sticky map notice is up for as long as
        // the map is -- would swap its LETTER correctly and keep the edge tint
        // of the state it used to be in, so an unbound cap would draw a dash
        // inside a bound-looking plate. Killing the transition here makes the
        // whole glyph follow the binding.
        //
        // SCOPED TO THIS COMPONENT ON PURPOSE. The same shape is live on every
        // plate in the project that recolours its own edge, and fixing it in
        // index.css means touching the focus animation of every panel and
        // button in the interface. That is a real issue and a separate one.
        //
        // CAVEAT WORTH KEEPING: this was measured in the harness browser, which
        // is Chrome 148. The game is CEF 103 and may not share the fault. This
        // line is correct either way -- a cap has nothing to animate -- so it
        // is safe under both, but the BUG is only confirmed on 148.
        transition: 'none',
      }}
    >
      {key || '--'}
    </span>
  )
}

/**
 * The token Lua writes where a key belongs: `{key:brptt}`.
 *
 * ═══ WHY A TOKEN AND NOT THE LETTER ═══
 *
 * The sentences these appear in are LUA's and have to stay Lua's -- one place
 * for the wording, which is the rule VoiceNotice.tsx and Settings.tsx both
 * argue at length and which this project's entire voice history is the case
 * for. So the page cannot compose the sentence, and Lua cannot draw the plate.
 * What crosses the boundary is therefore the sentence with a HOLE in it, and
 * the hole names the COMMAND.
 *
 * That is also the only shape that satisfies #209's live-rebind constraint on a
 * surface as long-lived as a sticky notice: had Lua substituted the letter
 * before sending, the string would be a photograph of the binding at the moment
 * it was composed, and rebinding underneath it would leave a notice naming a
 * key that no longer does anything. The command name does not go stale.
 *
 * DELIBERATELY UNLIKE ANYTHING A HUMAN WOULD TYPE. The stack also carries
 * player-authored strings (names in squad and kill notices), and this is the
 * one place they meet a substitution. Braces plus the `key:` prefix plus an
 * identifier is not a shape a player name can be, and a string that does not
 * match is passed through untouched and uncopied.
 */
const KEY_TOKEN = /\{key:([A-Za-z0-9_]+)\}/g

/**
 * A sentence with its keys drawn as keys.
 *
 * Renders `text` as-is except for `{key:command}` tokens, each of which becomes
 * a `KeyCap`. A string with no token is returned untouched and costs nothing --
 * which is almost all of them, since this sits on the notice stack that every
 * pickup, kill and squad event passes through.
 */
export function KeyText({ text, fs }: { text: string; fs?: string }) {
  // A FRESH REGEX PER CALL. A /g literal carries `lastIndex` between calls, so
  // a shared one would start the second notice's scan wherever the first
  // finished and silently miss its token.
  const re = new RegExp(KEY_TOKEN.source, 'g')
  const parts: ReactNode[] = []
  let last = 0
  let m: RegExpExecArray | null

  while ((m = re.exec(text)) !== null) {
    // The capture group is not optional in the pattern, so it is always a
    // string here; the local is what tells the compiler so under
    // noUncheckedIndexedAccess, and it keeps the JSX below readable.
    const command = m[1] ?? ''
    if (m.index > last) parts.push(text.slice(last, m.index))
    // Keyed on the offset as well as the command: one sentence may name the
    // same action twice, and two children with one key is a React warning and
    // a reconciliation bug.
    parts.push(<KeyCap key={`${m.index}:${command}`} command={command} fs={fs} />)
    last = m.index + m[0].length
  }

  if (last === 0) return <>{text}</>
  if (last < text.length) parts.push(text.slice(last))
  return <>{parts}</>
}
