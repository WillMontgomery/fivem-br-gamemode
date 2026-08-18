import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'
import { SQUAD_SLOT_ID } from '../hud/Hud'
import { CHAT_COLUMN_ID, CHAT_LOG_MAX_REM } from '../chat/Chat'

/** Breathing room between this card and whatever it is keeping clear of. */
const GAP_REM = 0.75

/**
 * THE SHORTEST THIS CARD IS ALLOWED TO BE, whatever the band says.
 *
 * A band computed from two measured edges can close: a four-plate squad panel
 * at a large interface scale, a generous safe zone and a 720p screen all push
 * from the same direction, and an absolutely positioned box with `top` and
 * `bottom` both set simply resolves to zero height rather than overflowing --
 * so the card would vanish instead of scrolling, which is a worse failure than
 * the overlap this whole mechanism exists to remove.
 *
 * THE FLOOR IS TAKEN OUT OF THE CHAT'S SIDE and never the squad panel's. The
 * squad panel is live vitals -- health, shield and a bleed clock somebody is
 * deciding on -- while the chat log is a fading transcript that is already
 * mostly empty space; if one of the two has to be covered in a corner case, it
 * is the one whose content is recoverable by scrolling it back.
 */
const MIN_BAND_REM = 14

/**
 * THE VERTICAL BAND THIS CARD IS ALLOWED TO OCCUPY, in viewport pixels.
 *
 * THE OWNER ASKED WHETHER IT ALREADY DID THIS AND THE HONEST ANSWER WAS NO
 * (2026-08-17: "have you confirmed it resizes vertically when the list is
 * larger, and scrolls once the vertical height would overlap with the chat and
 * our squad panel").
 *
 * Half of it was already true and half was not. The card is a flex column with
 * a `shrink-0` header, a `shrink-0` footer and a `min-h-0 flex-1 overflow-y-auto`
 * roster, so it DOES grow with the list and it DOES scroll once it stops
 * growing. What it stopped growing at was a hardcoded 74vh max-height, centred
 * on the viewport -- a number with no relationship to anything else on screen.
 * Measured in the harness at 1920x1080 with a four-person squad and a full chat
 * log:
 *
 *     entries   card top..bottom      grows      scrolls
 *        5      395 .. 685  (290px)   yes        no
 *       20      148 .. 932  (784px)   yes        no
 *       60      140 .. 940  (799px)   capped     yes   (the old 74vh cap = 799px)
 *
 * The chat log occupied 670..830 and the squad panel 35..305, both in the same
 * left column and both fully inside this card's 42..378 horizontally. So the
 * card was over the chat from FIVE entries and over the squad panel from about
 * thirteen -- and it is near-opaque, so it was not overlapping them, it was
 * hiding them. Sixty entries is not the failing case; five is.
 *
 * SO THE CAP IS THE NEIGHBOURS NOW, and it is MEASURED rather than derived:
 *
 *   the top     the squad panel's rendered bottom edge. Its height is data --
 *               nothing between zero and four plates, and a plate loses its two
 *               bars when its player is out -- so a rem constant would be wrong
 *               for every squad except the one it was written against.
 *   the bottom  the chat column's anchored bottom edge, less the most its log
 *               can ever grow to (CHAT_LOG_MAX_REM). Its maximum rather than
 *               its current height, or this card would resize itself every time
 *               somebody spoke and again when the log faded.
 *
 * Either neighbour being absent -- solo, or chat unmounted between rounds --
 * falls back to the safe zone, which is the edge of the usable screen and
 * exactly the right answer when there is nothing to avoid.
 */
type Band = { top: string; bottom: string }
const FULL_BAND: Band = { top: 'var(--hud-top)', bottom: 'var(--safe-y)' }

/**
 * Who is in this match, and the way to report them.
 *
 * A PANEL, NOT A PAGE (owner, 2026-08-16). This was a full-screen sheet and it
 * was wrong for the same reason a full-screen map would be: the player is
 * standing in a battle royale while they read it. An opaque overlay means the
 * one thing they cannot do while checking who is left is see the fight they are
 * in. So it is a card down one side, the game stays visible behind it, and the
 * root is pointer-events:none -- a click outside the card reaches the game
 * rather than being swallowed by an invisible full-screen div.
 *
 * THE LEFT SIDE, on the owner's call after playing with it on the right
 * (2026-08-16). Nothing about the shape changed; it is the side that changed.
 * `.page-in` already enters from translate3d(-1.4rem, ...), so on this side the
 * existing animation reads as the card sliding in from the edge it lives on --
 * which is why there is no new keyframe here.
 *
 * IT SITS OVER THE CHAT, and that falls out of the z ladder rather than from a
 * number chosen here: this renders inside a `.page` (z-index 50, "above the HUD
 * (40) and below the black curtain (60)" -- index.css), and the chat column is
 * HUD chrome with no z-index at all. On the right the two never met. On the
 * left they overlap in the lower corner, so the ladder is now load-bearing and
 * is written down instead of assumed.
 *
 * TWO MODES ON ONE CARD. By default it is a list: who is here, who is still
 * alive, who has gone. Pressing "Report player" turns the same rows into a form
 * -- each row becomes a tick target, a category picker appears under the ones
 * you tick, and a Send appears once at least one is ticked.
 *
 * That is one surface rather than two because the list IS the form's subject.
 * A separate report dialog would mean picking a name twice: once to find them,
 * once to accuse them.
 *
 * STRIPPED BACK IN #142, and every removal is the owner's, so they are recorded
 * here rather than argued for:
 *
 *   the ALIVE COUNT      "that's already in the top right corner of the
 *                        screen." It was, and a second copy of a number that
 *                        moves is a second number to disbelieve.
 *   the REPORT ALLOWANCE "We don't need to tell a player how many people they
 *                        can report, or how many reports are left." The limits
 *                        are untouched and still enforced server-side; they
 *                        stopped being advertised, which also took `remaining`
 *                        off the wire entirely -- see br_core/server/players.lua.
 *   the CLOSE BUTTON     "Having a 'close' button is not necessary." It was
 *                        only ever there because the key that opened this could
 *                        not close it; that is fixed below, so the workaround
 *                        goes with the problem.
 *   the NOTE FIELD       "We don't need a custom text field for reports. Just
 *                        the dropdown." It had never reached anywhere either:
 *                        br_ddb writes `note: null` unconditionally.
 *
 * NOTHING HERE IS AUTHORITATIVE. The bucket was resolved server-side, the
 * categories arrived with the list, and every rule this screen appears to
 * enforce is enforced again on submit. A modified client can tick anything it
 * likes and gets the same answer an honest one does.
 *
 * WHAT IS DELIBERATELY NOT SHOWN: positions, health, inventory, and the match
 * id. The roster projection already withholds them; this does not ask.
 */
export default function PlayerList() {
  const list = useUi((s) => s.players)
  const result = useUi((s) => s.reportResult)
  const setResult = useUi((s) => s.setReportResult)
  const keybinds = useUi((s) => s.keybinds)
  const rawKeys = useUi((s) => s.keybindsRaw)

  const [reporting, setReporting] = useState(false)
  const [picked, setPicked] = useState<Record<number, string>>({})

  /**
   * WHAT THE PLAYER IS LOOKING FOR, AND THE FIELD THEY TYPED IT INTO.
   *
   * Owner, 2026-08-17: "can you have an agent add a search function in the
   * in-game player menu? the list should truncate while typing and it should
   * clear out the search when the page is dismissed."
   *
   * The ref is not decoration. This component's dismiss listener is on `window`
   * in the CAPTURE phase (see below), so it sees every keystroke BEFORE the
   * field does -- `e.target` against this ref is the only way that handler can
   * tell "the player is typing" from "the player pressed the close key".
   */
  const [query, setQuery] = useState('')
  const searchRef = useRef<HTMLInputElement>(null)

  /**
   * THE SEARCH CLEARS WHEN THE PANEL IS DISMISSED, AND IT NEEDS A LINE OF ITS
   * OWN RATHER THAN THE UNMOUNT THAT ALREADY LOOKS LIKE ONE.
   *
   * The obvious reading is that this is free: `App.tsx` renders this inside
   * `<Page show={focus === 'players'}>`, Page drops its child when the screen
   * closes, and React state dies with the component -- which is exactly the
   * argument br_ui/client/players.lua makes for report mode ("the mode is React
   * state on a component that unmounts with the panel, so it cannot survive to
   * be wrong the next time this opens").
   *
   * IT IS FREE ONLY IF THE UNMOUNT ACTUALLY HAPPENS, AND FOR 200ms IT DOES NOT.
   * Page keeps its child MOUNTED for the length of the exit animation --
   * `EXIT_MS = 200`, ui/Page.tsx -- so a close and a re-open inside that window
   * clear the pending timer and hand back THE SAME COMPONENT INSTANCE, with all
   * of its state. And the key that opens this panel is a LATCH on tilde, which
   * is the one control shape where a player taps twice in well under 200ms as a
   * matter of course. So the stale-filter case the owner named is not
   * hypothetical, it is the fast double-tap.
   *
   * KEYED ON FOCUS, NOT ON THE CLOSE BUTTON, so it covers every way this panel
   * goes away and not just the one the page initiates: the player's key, a
   * successful report (Lua hides the panel behind it), the bus taking it away
   * mid-descent, the focus watchdog, `brfocus clear`. All of them land as the
   * same thing -- `focus` stops being 'players' -- which is the one fact worth
   * listening to.
   *
   * ONLY THE QUERY IS CLEARED, and the asymmetry with `reporting`/`picked` is
   * deliberate rather than an oversight. A surviving SELECTION is the panel
   * being kind (the note on `result` below calls losing one "a small cruelty");
   * a surviving FILTER is the panel LYING, because it comes back with rows
   * missing and nothing on screen saying a filter is the reason. Same 200ms
   * window, opposite right answers.
   */
  const focused = useUi((s) => s.focus === 'players')
  useEffect(() => {
    if (!focused) setQuery('')
  }, [focused])

  // The screen envelope moves --hud-top and the radar rectangle, which moves
  // both of the boxes measured below without anything resizing. Subscribed to
  // rather than polled, so the band is recomputed exactly when it can change.
  const screen = useUi((s) => s.screen)
  const [band, setBand] = useState<Band>(FULL_BAND)

  useLayoutEffect(() => {
    const compute = () => {
      // The measured boxes are viewport coordinates and so is this card's
      // containing block: `.hud-safe` is `position: fixed; top: 0; height: 100%`,
      // so an absolute child's `top: Npx` IS N pixels down the viewport. Checked
      // in the harness -- the old `top-1/2` card centred on exactly 540 at
      // 1080p. No conversion, and nothing here has to know about the safe-zone
      // padding.
      const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
      const gap = GAP_REM * rem

      const slot = document.getElementById(SQUAD_SLOT_ID)
      const chat = document.getElementById(CHAT_COLUMN_ID)

      // A zero-height slot is a solo player: the wrapper is still there, its
      // bottom is its top, and the card simply starts where the column does.
      const topPx = slot ? slot.getBoundingClientRect().bottom + gap : null
      const chatCeiling = chat
        ? chat.getBoundingClientRect().bottom - CHAT_LOG_MAX_REM * rem
        : null
      let bottomPx = chatCeiling != null
        ? window.innerHeight - chatCeiling + gap
        : null

      // The band can close on a short screen with a full squad. See MIN_BAND_REM.
      if (topPx != null && bottomPx != null) {
        const floor = MIN_BAND_REM * rem
        if (window.innerHeight - topPx - bottomPx < floor) {
          bottomPx = Math.max(0, window.innerHeight - topPx - floor)
        }
      }

      const next: Band = {
        top: topPx != null && topPx > 0 ? `${Math.round(topPx)}px` : FULL_BAND.top,
        bottom: bottomPx != null && bottomPx > 0
          ? `${Math.round(bottomPx)}px` : FULL_BAND.bottom,
      }
      // Compared before setting: this runs from a ResizeObserver, and a state
      // write per observation on a panel that is open during a firefight is a
      // render loop waiting to happen.
      setBand((prev) => (prev.top === next.top && prev.bottom === next.bottom)
        ? prev : next)
    }

    compute()

    // The squad panel is the only neighbour whose SIZE moves on its own -- a
    // mate goes down, a mate is out, the row loses its bars. The chat column is
    // anchored and reserved, so it needs no observer.
    const slot = document.getElementById(SQUAD_SLOT_ID)
    const ro = slot ? new ResizeObserver(compute) : null
    if (ro && slot) ro.observe(slot)
    window.addEventListener('resize', compute)
    return () => {
      ro?.disconnect()
      window.removeEventListener('resize', compute)
    }
  }, [screen])

  /**
   * The only thing this panel asks Lua for. STATE, NOT A TOGGLE -- `open:
   * false` rather than "flip it" -- so a message lost on a busy frame costs one
   * stale frame instead of leaving the panel and the cursor permanently
   * disagreeing about which of them exists.
   */
  const close = () => { void fetchNui(CB.PLAYERS_FOCUS, { open: false }) }

  // SWITCHING MODES IS A LOCAL EVENT NOW. It used to be a focus change as well,
  // because report mode needed a screen that gave game input back up; both
  // modes hold the same focus since #135, so there is nothing to tell Lua.
  const enterReport = () => {
    setReporting(true)
  }

  const leaveReport = () => {
    setReporting(false)
    setPicked({})
  }

  /**
   * WHICH KEYPRESS MEANS "SHUT THIS", BY VIRTUAL-KEY CODE.
   *
   * THE OPEN KEY HAS TO CLOSE IT AND ONLY THE PAGE CAN HEAR IT (#142, owner:
   * "Tilde must dismiss the panel while it is open. It currently does not").
   *
   * This was named as a risk when the panel stopped keeping game input in #135
   * and it turned out to be exactly right. Two Lua-side routes exist for a
   * keypress and NUI focus closes both:
   *
   *   * the engine's RegisterKeyMapping binding needs the GAME to receive the
   *     key, and with the cursor ours and keep-input off it receives nothing;
   *   * br_core's raw key layer reads the keyboard directly and is what
   *     normally survives that -- but its own frontend suppressor already
   *     records that "the raw layer cannot see Escape while CEF holds the
   *     cursor" (br_core/client/natives.lua), and this panel holds it.
   *
   * So the key that opened the panel is invisible to everything that could act
   * on it, which is why Escape and a Close button were the workarounds. The
   * page, though, has DOM focus by definition while the cursor is ours, so a
   * keydown listener here is the one thing certain to see the press. It then
   * asks Lua to close, exactly as #83 raises the pause menu from the lobby --
   * the callback it uses is the same one the (now deleted) Close button used,
   * so nothing on the Lua side had to learn a new message.
   *
   * BY CODE, NOT BY `e.key`, BECAUSE THE KEY IS REBINDABLE. br_core's binding
   * table is the authority and it travels on the keybinds envelope, which is
   * pushed on every `br:ui:ready` -- so `brplayers`.vk is present without the
   * player ever opening Settings. Comparing `e.keyCode` against it is the same
   * comparison Keybinds.tsx makes when CAPTURING a rebind, so a key bound
   * through that screen is a key recognised by this one, whatever it is.
   *
   * 0xC0 IS THE FALLBACK AND IS ONLY REACHED IN A GAP. It is the raw layer's
   * own default for this action (tilde), used for the frames between the page
   * mounting and the first keybinds envelope landing.
   *
   * F2 ONLY WHEN THE RAW LAYER IS OFF, because that is the only situation in
   * which F2 opens this panel: it is the ENGINE-side default, inert on every
   * client where the raw reader is running. Accepting it unconditionally would
   * mean F2 closing a panel it could not have opened.
   */
  const closeCodes = useMemo(() => {
    const codes = new Set<number>()
    const row = keybinds.find((k) => k.command === 'brplayers')
    codes.add(row?.vk ?? 0xc0)
    if (!rawKeys) codes.add(0x71)
    return codes
  }, [keybinds, rawKeys])

  // Escape backs out one step -- report mode first, then the panel. Two steps
  // because losing a five-name selection to a mis-hit Escape is the kind of
  // small cruelty that stops people reporting at all.
  //
  // THE OPEN KEY DOES NOT DO THAT, and the asymmetry is deliberate. Tilde is a
  // latch: it means "this panel, on or off", and a latch that only half
  // released on the second press would be the same complaint this issue is
  // about wearing a different shape. Escape is the careful way out; the key you
  // opened with is the blunt one.
  //
  // No dependency array on purpose -- the handler closes over `reporting`, and
  // a stale closure here would make Escape back out of a mode the player has
  // already left.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // IS THE PLAYER TYPING? Asked first, because both branches below mean
      // something different when they are.
      //
      // THE LISTENER IS ON `window` IN THE CAPTURE PHASE, WHICH IS WHY THIS
      // CANNOT BE DONE THE USUAL WAY. Capture runs window -> target, so this
      // handler fires BEFORE the input's own -- an `onKeyDown` with
      // stopPropagation on the field, which is how Settings' name field and the
      // chat composer keep their keystrokes to themselves, is powerless here.
      // It runs second. The check has to happen at this end, on `e.target`.
      const typing = e.target === searchRef.current

      if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        play('ui.back')
        // ESCAPE BACKS OUT ONE STEP, AND THE SEARCH IS NOW THE INNERMOST ONE.
        //
        // The ladder was report-mode-then-panel and the reasoning is directly
        // below; a filter with something in it is another layer of exactly the
        // same kind, so it goes on the same ladder rather than being given a
        // rule of its own. Escape with a non-empty field CLEARS THE FIELD and
        // leaves the panel up, with the caret still in it.
        //
        // WHY NOT "ESCAPE ALWAYS CLOSES": because the field is the one place on
        // this panel where Escape is a reflex borrowed from somewhere else. A
        // player who has typed four letters into a search box and wants the
        // whole list back presses Escape -- every browser, every launcher and
        // this project's own chat composer has taught them that. Closing the
        // panel on them instead is the mis-hit this ladder exists to prevent,
        // and it costs a re-open plus the tilde latch to undo.
        //
        // AND ONLY WHEN THERE IS SOMETHING TO CLEAR. An empty field is not a
        // step, so Escape falls straight through to report mode and then to
        // closing -- pressing Escape twice always leaves, which is the property
        // that keeps this predictable. `query` and not `query.trim()` on
        // purpose: a field holding nothing but spaces looks empty, matches
        // everything, and would otherwise eat an Escape with no visible reason.
        if (typing && query !== '') { setQuery(''); return }
        if (reporting) leaveReport()
        else close()
        return
      }
      if (!closeCodes.has(e.keyCode)) return

      // THE CLOSE KEY IS A CHARACTER WHILE THE FIELD HAS FOCUS, AND THAT IS THE
      // WHOLE REASON THIS BRANCH GREW A GUARD.
      //
      // `closeCodes` is virtual-key codes, because the key is rebindable -- and
      // the DEFAULT is 0xC0, which is the backtick/tilde key. Without this,
      // typing a backtick into the search box closed the panel. That much is a
      // curiosity; the real damage is that br_core's binding table is the
      // authority here, so a player who rebinds the player list onto a LETTER
      // (the Settings screen lets them, and the raw layer's VK is whatever they
      // picked) gets a search field that dismisses the panel every time that
      // letter appears in a name they are trying to type.
      //
      // A key bound to "open/close this panel" means that while the panel has a
      // text cursor in it. This does NOT weaken the fix it guards -- the panel
      // is still closed by that key from anywhere else on the card, including
      // the moment the field is blurred -- it just stops the latch firing on
      // input the player intended as text.
      if (typing) return

      e.preventDefault()
      e.stopPropagation()
      play('ui.back')
      close()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  // A refused report leaves the form up so the selection is not lost -- the
  // reason is in a toast, and retyping five names because the server said no
  // is a punishment for the wrong party. That matters more since #143: the
  // commonest refusal is now "you have already reported X in this match", and
  // the fix for it is to untick one row and send the rest.
  //
  // A successful one is cleared, because Lua closes the panel behind it.
  useEffect(() => {
    if (!result) return
    if (result.ok) {
      setPicked({})
      setReporting(false)
    }
    setResult(null)
  }, [result, setResult])

  /**
   * REPORTABLE IS NOT THE SAME AS LISTED. You are in the list and cannot be
   * ticked; everyone else can, including players who have left.
   */
  /**
   * THE LIST, TRUNCATED BY WHAT IS IN THE FIELD.
   *
   * LIVE, NOT ON SUBMIT -- "the list should truncate while typing". There is no
   * Enter key to press and no debounce: the roster is at most the server's
   * player cap, the test is one `includes` per row, and a filter that lags
   * behind the caret reads as a dropped keystroke on a panel that is already
   * competing with a firefight for the player's attention.
   *
   * FORGIVING ON PURPOSE. Case-insensitive, and a SUBSTRING rather than a
   * prefix -- the player is looking for somebody they half-remember seeing in a
   * kill feed, so "kes" has to find "xX_Kestrel_Xx" and not just names that
   * start with it. Nothing clever beyond that: no fuzzy matching, no ranking,
   * no reordering. Rows staying in their original order is what lets somebody
   * type two letters, recognise the name they wanted and stop.
   *
   * TRIMMED, because a trailing space is invisible and would otherwise be the
   * difference between a name matching and the panel claiming nobody does. The
   * trim is only for the TEST -- what the player typed stays in the field
   * exactly as they typed it.
   *
   * FILTERING IS THE ONLY THING IT DOES. It does not touch `list.maxTargets`,
   * it does not untick anybody, and a ticked row that scrolls out of the filter
   * is still ticked and still sent -- `picked` is keyed by src and `selected`
   * below reads it directly rather than reading the rows. Searching is a way of
   * looking at the list, not a way of editing a report.
   */
  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return list.players
    return list.players.filter((p) => p.name.toLowerCase().includes(q))
  }, [list.players, query])

  const selected = useMemo(() => Object.keys(picked).map(Number), [picked])

  const toggle = (src: number) => {
    setPicked((prev) => {
      if (prev[src]) {
        play('ui.select')
        const next = { ...prev }
        delete next[src]
        return next
      }
      // THE CAP IS ENFORCED HERE AND NOW HAS TO BE AUDIBLE. It used to sit
      // beside an "n/5 picked" readout, so a sixth tick that did not take
      // explained itself; that readout went with the allowance text in #142, so
      // a silent refusal would now just look like a broken checkbox. The server
      // refuses the same submission for the same reason and costs the player
      // nothing when it does -- this is only about not sending it.
      if (Object.keys(prev).length >= list.maxTargets) {
        play('ui.error')
        return prev
      }
      play('ui.select')
      return { ...prev, [src]: list.defaultCategory }
    })
  }

  const submit = () => {
    if (selected.length === 0) { play('ui.error'); return }
    play('ui.select')
    void fetchNui(CB.REPORT_SUBMIT, {
      targets: selected.map((src) => ({ src, category: picked[src] })),
    })
  }

  return (
    // NO BACKDROP AND NO POINTER EVENTS ON THE ROOT. The game is meant to show
    // through, and a full-screen interactive layer over a live match eats the
    // clicks that should have been shots.
    <div className="pointer-events-none fixed inset-0 z-50">
      {/* THE SAME BOX THE HUD LAYS OUT IN, so the panel follows the player's
          safe-zone slider and the ultrawide clamp instead of pinning itself to
          the physical edge of the glass. On a 32:9 panel an element anchored to
          the raw viewport sits a head-turn away from everything else on screen
          (#20), and this card is meant to be read at a glance during a fight.
          That is also why the side swap below is one property and not a
          rewrite: both edges of this box are already the right edges. */}
      <div className="hud-safe">
        {/* THE ANCHOR IS THIS DIV AND NOT THE PLATE, and that is the whole fix
            rather than a tidy-up (owner, 2026-08-16: "you got your X coords
            mixed up").

            `.plate` declares `position: relative` -- it has to, because its
            two redrawn chamfers are absolutely positioned children of it. But
            index.css opens with `@tailwind utilities`, so every utility class
            is emitted ABOVE `.plate` in the sheet. `.absolute` and `.plate`
            are both one class of specificity, so the later rule wins and the
            card was `position: relative` with `right`/`top` doing nothing but
            nudging it out of normal flow -- 22px LEFT of the document origin,
            hanging off the left edge of the screen with most of the panel cut
            off. It rendered on the wrong side of the screen entirely.

            Anchoring on a plain div sidesteps the collision instead of
            fighting it, and it takes the translate off the plate as well --
            `.plate` transitions `transform`, and a positioning transform on a
            surface that animates transform is a trap waiting for whoever adds
            the next state to this card.

            AND THE SIDE IS THIS ONE LINE, which is the point of having fixed
            the anchor properly first. `left` instead of `right`, against the
            same safe-zone inset, on the same box -- no negative margins, no
            second transform, and nothing that has to know how wide the card
            is in either mode. */}
        {/* THE BAND, AND THE CARD CENTRED IN IT. `top-1/2 -translate-y-1/2` on
            a card with a hardcoded 74vh max-height is what put this over the squad
            panel -- see the note on Band above for the measurements. Giving the
            anchor a top AND a bottom makes its height the free space itself, so
            `items-center` still centres the card the way it always did, and
            `max-h-full` is now a cap that means something. */}
        <div
          className="absolute flex items-center"
          style={{ left: 'var(--safe-x)', top: band.top, bottom: band.bottom }}
        >
          <div
            className="interactive plate flex max-h-full flex-col"
            style={{
              width: reporting ? '27rem' : '21rem',
              transition: 'width 140ms ease-out',
              ['--edgec' as string]: 'rgba(255,255,255,0.14)',
              ['--plate-fill' as string]: 'rgba(10,12,18,0.90)',
              backdropFilter: 'blur(6px)',
            }}
          >
            {/* THE HEADER SAYS WHAT THIS IS AND NOTHING ELSE. It carried the
                alive count on the right, and #142 took it off: the HUD already
                draws that number in the top-right corner, and two copies of a
                figure that changes every elimination is one copy too many --
                the moment they disagree for a frame, neither is trusted. */}
            <div className="shrink-0 px-4 pt-3.5 pb-3">
              <div className="micro-label">This match</div>
              <h2 className="font-display text-[1.35rem] uppercase leading-none tracking-[0.09em]">
                {reporting ? 'Report' : 'Players'}
              </h2>
            </div>

            {/* THE SEARCH ROW, AND WHERE ITS HEIGHT COMES OUT OF.

                IT IS A `shrink-0` SIBLING OF THE ROSTER, WHICH IS THE ENTIRE
                REASON IT DOES NOT RE-OPEN THE BUG THE BAND ABOVE JUST FIXED.
                The card is `flex max-h-full flex-col` inside an anchor whose
                height IS the free band, so the card cannot get taller than the
                band no matter what is put in it. Its three existing children
                divide that height: two `shrink-0` ends and a `min-h-0 flex-1`
                middle. Adding a fourth `shrink-0` child therefore takes its
                height OUT OF THE SCROLLING REGION -- flexbox does the
                subtraction, there is no second measurement to keep in sync with
                the band, and the card's outer box does not move by a pixel.

                MEASURED IN THE HARNESS, not derived -- full four-plate squad,
                chat column mounted, so both neighbours are present and the band
                is at its tightest. Heights in CSS pixels:

                                       card   header  SEARCH  roster  footer
                   1920x1080 (rem 16)  374     62.4    46.3   209.8    53.5
                   1280x720  (rem 11)  238     42.9    32.5   122.6    37.9

                THE CARD'S OUTER RECT DID NOT MOVE: 284..658 at 1080p and
                197..435 at 720p, both identical to the same measurement taken
                before this row existed. The roster absorbed the whole cost --
                256.1 -> 209.8 at 1080p and 155.1 -> 122.6 at 720p, each a drop
                of exactly the search row's height. That equality is the
                invariant to re-check if any of this is edited: the card's outer
                rect must not move when this row is added or removed.

                What it costs the reader is rows, and only rows: 8.0 visible
                became 6.6 at 1080p, and 7.0 became 5.6 at 720p.

                720p IS THE CASE THAT DECIDED THE SIZING, and not for the
                obvious reason. The root font size is
                `clamp(11px, calc(1.481vh * var(--ui-scale)), 28px)`, so 720p
                does NOT scale to 11/16ths of 1080p -- it lands on the 11px
                FLOOR, which leaves every rem here bigger, relative to the band,
                than it is at 1080p. The band lost 36% of its height between the
                two and the row only lost 30% of its own. So the row is kept to
                the smallest thing that is still a legible text field rather
                than taking the `py-2` the Settings name field uses, which would
                have cost another row of roster at the size least able to spare
                one.

                BELOW THE 720p TARGET THE MIN_BAND_REM FLOOR TAKES OVER AND THIS
                ROW IS EXPENSIVE, WHICH IS RECORDED RATHER THAN FIXED HERE. The
                floor is not reached at 720p (card 238px against a 154px floor)
                nor at 640px of viewport height (179px, 2.9 rows). It engages
                below roughly 620px, and there the card is pinned at 14rem while
                this row still takes its 32.5px -- 1280x600 measured a 153px card
                with a 38px roster, 1.7 rows, where before it would have held
                about three.

                RAISING MIN_BAND_REM TO COMPENSATE WAS CONSIDERED AND NOT DONE.
                The floor is taken out of the chat's side (see its note), so
                buying those rows back means covering more of the chat -- which
                is the exact regression the measured band was just introduced to
                remove, and doing it silently for a viewport shorter than the
                supported floor is a bad trade made in the dark. Flagged in the
                hand-over instead; if a 600px-tall client turns out to be real,
                the search row is the thing that should fold away there, not the
                chat.

                AND IT SITS ABOVE THE SCROLL, NOT INSIDE IT. A field inside
                `overflow-y-auto` scrolls away from the player the moment they
                use it -- they type, the list jumps, and the thing they are
                typing into is off the top of its own container. */}
            <div className="shrink-0 px-4 pb-3">
              <div className="relative">
                <input
                  ref={searchRef}
                  type="text"
                  value={query}
                  maxLength={24}
                  spellCheck={false}
                  autoComplete="off"
                  aria-label="Search players by name"
                  placeholder="Search names…"
                  onChange={(e) => setQuery(e.target.value)}
                  /* Belt to the capture-phase handler's braces. That handler
                     already spares this element (see `typing` above) and is the
                     one that actually decides, because capture beats bubble --
                     but this is the line every other text field in the project
                     carries (Settings' name field, the chat composer), and a
                     field that is the ONE exception is a field somebody
                     "fixes" later. It stops anything downstream of this element
                     seeing the keystroke. */
                  onKeyDown={(e) => e.stopPropagation()}
                  className="plate ts w-full bg-transparent px-2.5 py-1.5 pr-7
                             outline-none placeholder:text-white/25"
                  style={{
                    /* `.ts` AND `--fs`, NOT `text-[0.85rem] tscale`, AND THE
                       DIFFERENCE IS NOT STYLISTIC. index.css opens with
                       `@tailwind utilities`, so `.tscale` is declared after
                       every utility at the same specificity and WINS -- and it
                       resolves to `calc(1em * var(--text-scale))`, where `1em`
                       is the PARENT's size. So `text-[0.85rem] tscale` silently
                       throws the 0.85rem away and renders at the parent's size
                       instead. index.css records that trap biting three times.

                       `.ts` is the shape that survives it: the declared size
                       arrives as `--fs` and the multiply happens inside the
                       rule that owns the size. VERIFIED BY WHAT RENDERS rather
                       than by what the class says -- measured in the harness at
                       a 16px root, this field computes to 13.6px (0.85rem) with
                       the text slider at 1.0, and tracks the slider from there;
                       the roster rows beside it compute to 16px, because they
                       are `text-[0.9rem] tscale` and are living examples of the
                       trap. Matching their RENDERED size was not the goal -- the
                       field is deliberately a step smaller than the names it
                       filters, so the list stays the loudest thing on the
                       card. */
                    ['--fs' as string]: '0.85rem',
                    ['--edgec' as string]: 'rgba(255,255,255,0.16)',
                    ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
                    ['--cut-max' as string]: '0.4rem',
                  }}
                />
                {/* A CLEAR AFFORDANCE, BECAUSE THIS PANEL IS CURSOR-FIRST.
                    It takes the mouse away from the game to be used (#135), so
                    the player reading it has a cursor in their hand and no
                    reason to assume Escape is wired to anything. Escape does
                    clear the field and is the faster route; this is the one
                    that is visible.

                    Only present with something to clear -- an always-there ×
                    over an empty field is a control whose only function is to
                    do nothing.

                    preventDefault ON MOUSEDOWN so the button never takes focus
                    off the input. Without it the field blurs on the way to the
                    click, which silently re-points Escape at "close the panel"
                    -- the exact same trap the chat composer's channel button
                    documents. The explicit focus() after is for the keyboard
                    route, where the button legitimately has focus and the caret
                    should come back to the field it just emptied. */}
                {query !== '' && (
                  <button
                    type="button"
                    aria-label="Clear search"
                    className="btn absolute right-1 top-1/2 grid size-5 -translate-y-1/2
                               place-items-center rounded-sm"
                    style={{ color: 'rgba(255,255,255,0.45)' }}
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => {
                      play('ui.back')
                      setQuery('')
                      searchRef.current?.focus()
                    }}
                  >
                    {/* Drawn rather than a glyph, for the reason the tick above
                        is: this interface ships two faces and neither is
                        guaranteed to carry a multiplication sign. */}
                    <svg
                      viewBox="0 0 10 10"
                      className="size-2.5"
                      aria-hidden="true"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.6"
                      strokeLinecap="round"
                    >
                      <path d="M1.8 1.8 L8.2 8.2 M8.2 1.8 L1.8 8.2" />
                    </svg>
                  </button>
                )}
              </div>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto thin-scroll px-2">
              {/* THREE OUTCOMES, NOT TWO, AND THE NEW ONE IS A STATE RATHER
                  THAN AN ABSENCE.

                  "Nobody else is here" is a fact about the MATCH. A filter that
                  matches nothing is a fact about the FIELD, and telling the
                  player the first when the second is true is the panel
                  reporting an empty server because they typed a typo.

                  So the searched-and-found-nothing case says so, names what it
                  searched for, and offers the way back. Rendering nothing at all
                  was the other option and it is the one that reads as broken:
                  a card with a header, a search box and a blank space under it
                  looks like a list that failed to load. */}
              {rows.length === 0 ? (
                query.trim() !== '' ? (
                  <p className="body-text px-2 pb-3">
                    No players match “{query.trim()}”.
                  </p>
                ) : (
                  <p className="body-text px-2 pb-3">Nobody else is here.</p>
                )
              ) : (
                <div className="flex flex-col gap-px pb-2">
                  {rows.map((p) => {
                    const on = picked[p.src] !== undefined
                    // You cannot report yourself, so no tick target is drawn.
                    // The server refuses it too, and so does
                    // BR.IncidentBuild.fromReport; this is only about not
                    // offering it.
                    const selectable = reporting && !p.you
                    const gone = p.left || p.state === 'dead'

                    /* THE `squad` TAG IS GONE, AND IT IS AN INFORMATION
                       DECISION RATHER THAN A WORDING ONE (owner, 2026-08-17:
                       "I don't want players to be able to tell how many squads
                       are left").

                       WHAT IT MEANT, since it is being deleted: it was the last
                       arm of this chain, so it read "alive, not downed, has not
                       left -- and `squadId` is non-null", i.e. THIS PLAYER IS IN
                       SOME SQUAD. Never "in MY squad" -- nothing here compared
                       it to the reader's own -- which is precisely the ambiguity
                       the owner could not resolve from the screen. And it was
                       close to information-free on its own terms: in a squad
                       match the server puts every participant in a squad, so it
                       appeared beside every living name; in solo it appeared
                       beside none. A tag that is either always or never on tells
                       a reader nothing they did not already know from the mode.

                       WHAT IT LEAKED is the reason it could not simply be
                       reworded. The count of living tagged names IS the number
                       of players still in squads, and paired with the alive
                       counter in the corner it is one subtraction from "how many
                       squads are left" -- the read the owner is closing. The
                       label was only the visible half: `squadId` itself is a
                       STABLE PER-SQUAD STRING, so a client that reads the
                       envelope could count distinct values directly and get the
                       exact figure. It is therefore dropped from the payload as
                       well, in br_ui/client/players.lua, and nothing in this
                       component reads it any more. */
                    const status = p.left
                      ? 'left'
                      : p.state === 'dead'
                        ? 'out'
                        : p.state === 'dbno'
                          ? 'down'
                          : ''

                    const name = (
                      <span className="min-w-0 flex-1 truncate text-[0.9rem] tscale leading-tight">
                        {p.name}
                        {p.you && <span className="micro-label ml-1.5">you</span>}
                      </span>
                    )

                    return (
                      <div key={p.src}>
                        {selectable ? (
                          /* THE WHOLE ROW IS THE TICK TARGET, not a 0.875rem
                             box beside it. A name is the thing the player is
                             actually aiming at, and this panel takes the cursor
                             away from the game to be used -- so the hit area
                             should be the width of the card, not the width of a
                             checkbox.

                             role=checkbox on a button rather than an <input>,
                             which is what makes the drawn box below possible at
                             all: see the note there. Space and Enter both
                             activate a button, and `.btn` gives it the
                             focus-visible ring every other control here has, so
                             the keyboard route is the browser's rather than
                             something reimplemented. */
                          <button
                            type="button"
                            role="checkbox"
                            aria-checked={on}
                            onClick={() => toggle(p.src)}
                            className="btn flex w-full items-center gap-2.5 rounded-sm px-2 py-1.5 text-left"
                            style={{
                              background: on ? 'rgba(255,255,255,0.06)' : 'transparent',
                              opacity: gone ? 0.5 : 1,
                            }}
                          >
                            {/* DRAWN, BECAUSE A NATIVE CHECKBOX IN CEF IS A
                                WINDOWS CHECKBOX (owner, #142: the controls
                                "look nothing like the rest of the interface").

                                Chrome 103 renders <input type=checkbox> with
                                the platform's own control -- a grey box with a
                                blue system tick that belongs to the operating
                                system, sitting inside a panel built out of
                                chamfered near-black plates. `accent-color`
                                recolours the tick and nothing else, which is
                                why the old one still read as an OS widget.

                                `appearance: none` plus drawn states is the
                                usual answer and would have worked; not
                                rendering an <input> at all is simpler and
                                strictly better here, because the row already
                                had to be a button for the hit area above. One
                                control, one element, and no reset property
                                whose support has to be checked against a 2022
                                browser.

                                The tick is an inline SVG rather than a glyph:
                                a text checkmark is a font decision, and this
                                interface ships two faces neither of which is
                                guaranteed to have one. */}
                            <span
                              aria-hidden="true"
                              className="grid size-3.5 shrink-0 place-items-center"
                              style={{
                                border: `1px solid ${on
                                  ? 'var(--color-royale-accent)'
                                  : 'rgba(255,255,255,0.34)'}`,
                                background: on
                                  ? 'var(--color-royale-accent)'
                                  : 'rgba(6,8,13,0.85)',
                                transition: 'background 120ms ease, border-color 120ms ease',
                              }}
                            >
                              {on && (
                                <svg
                                  viewBox="0 0 10 10"
                                  className="size-2.5"
                                  fill="none"
                                  stroke="#04222a"
                                  strokeWidth="1.9"
                                  strokeLinecap="square"
                                >
                                  <path d="M1.6 5.2 L4 7.5 L8.4 2.6" />
                                </svg>
                              )}
                            </span>

                            {name}

                            <span className="micro-label shrink-0">{status}</span>
                          </button>
                        ) : (
                          <div
                            className="flex items-center gap-2.5 rounded-sm px-2 py-1.5"
                            style={{ opacity: gone ? 0.5 : 1 }}
                          >
                            {/* A STATE DOT INSTEAD OF A SENTENCE. At this width
                                "Eliminated" beside every dead player is most of
                                the panel; the colour carries it and the word
                                only appears on the right when it is not
                                "alive". */}
                            <span
                              className="size-1.5 shrink-0 rounded-full"
                              style={{
                                background:
                                  p.state === 'dbno'
                                    ? 'var(--color-royale-warn, #e0a33a)'
                                    : gone
                                      ? 'rgba(255,255,255,0.3)'
                                      : 'var(--color-royale-accent)',
                              }}
                            />
                            {name}
                            <span className="micro-label shrink-0">{status}</span>
                          </div>
                        )}

                        {/* THE CATEGORY PICKER ONLY APPEARS FOR A TICKED ROW,
                            and it gets its own lines rather than sharing one --
                            at this width a name and a category side by side
                            truncates the name to nothing, which is the one
                            field that must stay legible on a report.

                            IT IS DRAWN OPEN RATHER THAN BEING A DROPDOWN, and
                            that is not a preference. A native <select> POPUP is
                            rendered by the browser outside the page and cannot
                            be styled on any engine -- not with appearance:none,
                            not with a pseudo-element, not at all -- so on CEF it
                            arrives as a Windows combo list over a battle royale.
                            The only way to control it is not to have one.

                            AND A CUSTOM POPUP WOULD HAVE BEEN WORSE THAN THIS
                            ONE. The list it would open into is inside
                            `overflow-y: auto` (the roster scrolls), so an
                            absolutely positioned menu is clipped by its own
                            scroll container -- the fix for which is portalling
                            it to the root, on a page whose root is deliberately
                            pointer-events:none. An always-open group has none of
                            that, costs one click fewer, and is the shape the
                            settings screen already uses for voice routing and
                            colourblind modes.

                            PLAIN BUTTONS, NOT role=radio. ARIA radios promise
                            arrow-key navigation and a single tab stop, and a
                            role that promises behaviour the code does not
                            implement is worse for a screen reader than no role
                            -- so this is a labelled group of pressable buttons,
                            which is exactly what it is, and Tab reaches every
                            one of them. Same call the settings screen made. */}
                        {selectable && on && (
                          <div
                            role="group"
                            aria-label={`Why you are reporting ${p.name}`}
                            className="mb-1.5 ml-8 mr-2 flex flex-wrap gap-1"
                          >
                            {list.categories.map((c) => {
                              const chosen = picked[p.src] === c.id
                              return (
                                <button
                                  key={c.id}
                                  type="button"
                                  aria-pressed={chosen}
                                  className={`btn plate px-2 py-1 text-[0.72rem] tscale${
                                    chosen ? ' is-active' : ''}`}
                                  style={{
                                    ['--edgec' as string]: chosen
                                      ? 'var(--color-royale-accent)'
                                      : 'rgba(255,255,255,0.16)',
                                    ['--plate-fill' as string]: chosen
                                      ? 'rgba(12,58,72,0.94)'
                                      : 'rgba(24,28,40,0.92)',
                                    ['--cut-max' as string]: '0.3rem',
                                    color: chosen
                                      ? 'var(--color-royale-accent)'
                                      : 'rgba(255,255,255,0.8)',
                                  }}
                                  onPointerEnter={() => play('ui.hover')}
                                  onClick={() => {
                                    play('ui.select')
                                    setPicked((prev) => ({ ...prev, [p.src]: c.id }))
                                  }}
                                >
                                  {c.label}
                                </button>
                              )
                            })}
                          </div>
                        )}
                      </div>
                    )
                  })}
                </div>
              )}
            </div>

            <div
              className="shrink-0 px-4 pt-3 pb-3.5"
              style={{ borderTop: '1px solid rgba(255,255,255,0.10)' }}
            >
              {reporting ? (
                <div className="flex items-center gap-2">
                  {/* SUBMIT ONLY EXISTS WITH A SELECTION. An always-present
                      submit on an empty form is a button whose only function is
                      to be refused. */}
                  {selected.length > 0 && (
                    <Btn variant="primary" size="sm" cue="ui.select" onPress={submit}>
                      Send {selected.length === 1 ? 'report' : `${selected.length} reports`}
                    </Btn>
                  )}
                  <Btn variant="ghost" size="sm" cue="ui.back" onPress={leaveReport}>
                    Cancel
                  </Btn>
                </div>
              ) : (
                /* ONE BUTTON, AND IT NAMES ITS OBJECT (#142). "Report" on its
                   own reads as a verb with no target on a panel that is a list
                   of people; "Report player" says which of the two it means.
                   It no longer changes to "No reports left" either -- the
                   allowance is not the panel's to talk about, and a player who
                   has spent it is told so by the refusal, in the same toast
                   that would have carried any other reason. */
                <Btn variant="ghost" size="sm" cue="ui.select" onPress={enterReport}>
                  Report player
                </Btn>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
