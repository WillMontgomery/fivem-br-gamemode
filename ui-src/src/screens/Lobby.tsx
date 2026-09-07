import Btn from '../ui/Btn'
import { play } from '../audio/cues'
import Ring from '../hud/Ring'
import { useEffect, useRef, useState } from 'react'
import { useUi, selMatch, selLobby, selSquad } from '../store'
import PartyPanel from './PartyPanel'
import Progress from './Progress'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'

/**
 * Lobby and queue.
 *
 * This is where HeroUI earns its place: a focused, interactive, non-realtime
 * screen. The in-match HUD deliberately avoids it -- see hud/Hud.tsx.
 *
 * HeroUI 2 API, not 3. FiveM's CEF is Chrome 103, and HeroUI 3 emits oklch and
 * color-mix throughout its colour system -- that build cannot parse them, so
 * the declarations are dropped and every component renders with no colour,
 * looking exactly like a stylesheet that failed to load. HeroUI 2 is a Tailwind
 * plugin generating HSL at build time and contains none of them.
 *
 * Mounted always, shown only when the match is WAITING, so the transition costs
 * no mount work.
 */
/**
 * The tutorial toggle (#261).
 *
 * ═══ A TOGGLE, NOT A CHECKBOX, AND NOT AN <input> ═══
 *
 * Owner, 2026-09-04: "Instead of a checkbox can we try a toggle for the
 * tutorial?" A checkbox is a form field you agree to; a toggle is a thing that
 * is ON, and this one arrives on.
 *
 * DRAWN RATHER THAN NATIVE, for the reason every control on this screen is
 * drawn: a platform checkbox or a platform switch in CEF brings styling that
 * matches nothing else in the game, and this sits directly above the loudest
 * button on the screen.
 *
 * `plate` IS THE SURFACE, so it belongs to the lobby rather than to the
 * tutorial -- the owner's rule that the whole feature follow "the same visual
 * and button structure as the existing UI". The edge takes the accent when on,
 * which is what accent means everywhere else: this concerns you.
 *
 * TRANSFORM ONLY on the knob, so it cannot cost layout while the lobby camera
 * is flying behind it.
 */
function TutorialToggle({ on, onChange, label }: {
  on: boolean
  onChange: (v: boolean) => void
  /** A node rather than a string, so a label can colour part of itself. */
  label: React.ReactNode
}) {
  return (
    // `btn` IS NOT DECORATION AND check-ui ENFORCES IT (R3): a bare button has
    // no press travel, no hover state and no sound, which is three ways this
    // would have felt unlike every other control on the screen. The cues below
    // are played by hand because a toggle is not a `Btn` -- it has two states
    // rather than one action -- but the feel is shared.
    //
    // THE COMMENT IS OUT HERE FOR A REASON. check-ui reads the opening tag by
    // scanning to the first `>` at brace-depth zero, so a comment INSIDE the tag
    // containing a literal angle bracket truncates the tag before `className`
    // and the rule fails on a button that satisfies it. Cost me a round.
    <button
      type="button"
      role="switch"
      aria-checked={on}
      className="btn interactive plate w-full flex items-center gap-3 px-4 py-2.5 mb-2.5 text-left"
      style={{ ['--edgec' as string]: on
        ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)' }}
      onPointerEnter={() => play('ui.hover')}
      onClick={() => { play('ui.select'); onChange(!on) }}
    >
      <span
        aria-hidden
        className="relative shrink-0"
        style={{
          width: '2.1rem', height: '1.05rem',
          background: on ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.14)',
          transition: 'background 140ms linear',
        }}
      >
        <span
          className="absolute top-[0.14rem] left-[0.14rem]"
          style={{
            width: '0.77rem', height: '0.77rem',
            background: on ? '#04222a' : 'rgba(255,255,255,0.75)',
            transform: on ? 'translateX(1.05rem)' : 'translateX(0)',
            transition: 'transform 160ms var(--ease-snap), background 140ms linear',
          }}
        />
      </span>
      <span className="tscale text-[0.85rem] text-white/80">{label}</span>
    </button>
  )
}

export default function Lobby({
  visible, under = false,
}: {
  visible: boolean
  /** A sub-screen (locker, market, settings) is over this one. */
  under?: boolean
}) {
  const match = useUi(selMatch)
  const lobby = useUi(selLobby)
  const squad = useUi(selSquad)
  // False from first paint until the boot choreography's flip -- a store
  // field with a boot-safe default, NOT read off the screen payload: the
  // `?? true` fallback raced the ready-handshake envelope and the menu
  // popped visible before learning the world was not there (filmed repro).
  // When Lua flips it, two 700ms fades run together: the menu fades IN
  // while the opaque backdrop fades OUT to the world.
  const worldReady = useUi((s) => s.worldReady)
  const locker = useUi((s) => s.locker)

  // ═══ THE GUIDED FIRST RUN'S OFFER (#261) ═══
  //
  // `tutorialOffer` is Lua's -- it decides whether this player is being offered
  // the walkthrough at all. `tutorialChecked` is the page's, because it is a
  // control the player is operating rather than a fact about the world, and it
  // starts TRUE: "A checkbox, default on".
  const tutorialOffer = useUi((s) => s.tutorialOffer)
  const tutorialChecked = useUi((s) => s.tutorialChecked)
  const tutorialRun = useUi((s) => s.tutorialRun)
  const tutorialStep = useUi((s) => s.tutorialStep)
  const tutorialGameOn = useUi((s) => s.tutorialGameOn)
  const setTutorialGameArmed = useUi((s) => s.setTutorialGameArmed)
  const pushNotice = useUi((s) => s.pushNotice)
  // Which screen is on top -- the offer is retired while Settings covers the
  // lobby, so the control does not vanish under the cursor that pressed it.
  const focus = useUi((s) => s.focus)
  const setTutorialGameOn = useUi((s) => s.setTutorialGameOn)
  const setTutorialChecked = useUi((s) => s.setTutorialChecked)
  const setTutorialRun = useUi((s) => s.setTutorialRun)
  const setTutorialOffer = useUi((s) => s.setTutorialOffer)

  // ONCE SHOWN, IT STAYS. The second toggle appears on the `ready` step and must
  // not vanish when that step is dismissed -- it is an offer about the next
  // thing, and the player has to be able to reach it afterwards.
  const [tutorialGameShown, setTutorialGameShown] = useState(false)
  useEffect(() => {
    if (tutorialStep === 'ready') setTutorialGameShown(true)
  }, [tutorialStep])

  // ═══ THE OFFER IS RETIRED BEHIND ANOTHER SCREEN, NOT IN FRONT OF THEM ═══
  //
  // Owner, 2026-09-04: "Once the 'start tutorial' button is clicked the first
  // time, the 'show me how to play' toggle should disappear when they're in the
  // 'settings' page. This is for the same reason as earlier, to not draw their
  // attention to the fact that it's gone."
  //
  // It used to vanish on the press itself, which is a control disappearing under
  // the cursor that just used it -- the eye goes straight to the gap. Settings
  // is the first screen the walkthrough sends them to, so the lobby is
  // rearranged while it is not being looked at, and they come back to a screen
  // that simply is that way. Same argument as the second toggle arriving on the
  // `ready` step rather than after it.
  useEffect(() => {
    if (tutorialRun && focus === 'settings') setTutorialOffer(false)
  }, [tutorialRun, focus, setTutorialOffer])

  // ═══ AND SQUADS IS PUT BACK TO SOLO ON THE WAY OUT OF SETTINGS ═══
  //
  // Owner, 2026-09-04: "when they come back from the settings page, please
  // automatically switch them back to solos."
  //
  // The walkthrough MADE them pick Squads, because the party controls only
  // exist on this screen in that mode and a card explaining them over a solo
  // lobby points at nothing. That is a demonstration, not a choice -- so
  // leaving it set would queue a brand new player into squads because the
  // tutorial needed the buttons on screen for one card.
  //
  // ON THE WAY BACK, not on the way in, so the switch happens behind the
  // Settings screen -- the same reason the offer is retired there. The lobby is
  // rearranged while nobody is looking at it.
  const wasInSettings = useRef(false)
  useEffect(() => {
    if (focus === 'settings') { wasInSettings.current = true; return }
    if (wasInSettings.current && tutorialRun) {
      wasInSettings.current = false
      pickMode('solo')
    }
  }, [focus, tutorialRun])

  /** Ready up reads Start tutorial only while the box is both offered and ticked. */
  const startTutorial = tutorialOffer && tutorialChecked

  /**
   * Begin the walkthrough instead of queueing.
   *
   * THE OFFER IS SPENT EITHER WAY, and that is the owner's rule: "Unchecking the
   * box will burn the one-time offer... Then they proceed into the match and the
   * box is gone." Taking it burns it too, so the checkbox comes down here as
   * well -- it has done its job and a walkthrough with its own invitation still
   * on screen behind it reads as unfinished.
   *
   * NOTHING IS PERSISTED YET. The flag that makes this a genuinely ONE-time
   * offer across sessions is the next piece of work; today the offer is raised
   * by /brtutorial and lives as long as the page does.
   */
  const beginTutorial = () => {
    setTutorialRun(true)
    // AND TELL LUA, WHICH TELLS THE SERVER. A player mid-walkthrough must not be
    // matchmade, must be on no warmup clock and must not be in a party -- all
    // three enforced server-side. Without this the whole hold is unreachable.
    void fetchNui(CB.TUTORIAL_SET, { run: true })
  }
  const [queued, setQueued] = useState(false)
  // WHY READY UP IS UNAVAILABLE, if it is. The party panel owns the answer --
  // it knows which way the player said they wanted a squad and whether they
  // have got one yet -- and this is where the button lives, so the reason
  // travels up rather than the button moving down.
  const [readyBlock, setReadyBlock] = useState<string | null>(null)

  /**
   * MAINTENANCE OUTRANKS THE PARTY PANEL'S REASON, and it has to.
   *
   * The server already refuses the queue during a drain -- that landed with the
   * blocker -- but the button stayed lit, so pressing it did nothing and said
   * nothing. A control that looks available and silently declines reads as a
   * broken menu, and the player presses it repeatedly rather than learning why.
   *
   * WORDED LIKE THE IN-MATCH NOTICE, deliberately: somebody in the lobby and
   * somebody mid-match are being told about the same event, and two different
   * sentences for one fact is how people conclude there are two problems. The
   * appended line is the part only a lobby player needs -- that waiting is the
   * whole job, and nobody has to do anything.
   */
  const maintenanceBlock =
    lobby?.wait?.reason === 'maintenance'
      ? 'A server update is pending, so no new matches can be started. '
        + 'It runs automatically once everyone has left — nothing to do but wait.'
      : null
  const [mode, setMode] = useState<'solo' | 'squad'>('solo')

  const inParty = squad.members.length > 1

  // Joining a party IS choosing squads -- there is deliberately no "in a party
  // but queued solo" state. Only the transition INTO a party flips the toggle:
  // reacting to `inParty` itself would fight the Solo button, which leaves the
  // party asynchronously and would be flipped back before the server answered.
  const wasInParty = useRef(inParty)
  useEffect(() => {
    if (inParty && !wasInParty.current) setMode('squad')
    wasInParty.current = inParty
  }, [inParty])

  const pickMode = (m: 'solo' | 'squad') => {
    setMode(m)
    // TELL THE SERVER, UNCONDITIONALLY, AND LET IT DECIDE.
    //
    // This used to be `if (m === 'solo' && inParty) fetchNui(SQUAD_LEAVE)` --
    // a rule enforced by the client, gated on a boolean the client derived
    // from a payload that has two different shapes (party in the lobby, squad
    // in a match). When that derivation was wrong, picking Solo silently did
    // not leave the party and there was nothing on the server to catch it
    // (user, 2026-08-09).
    //
    // Now the UI reports the CHOICE and the server applies the consequence.
    // It is idempotent, so this fires on every press without the UI needing
    // to know what state it is in -- which is exactly the knowledge that
    // failed.
    void fetchNui(CB.MODE_SET, { mode: m })
  }

  // THE SERVER IS THE AUTHORITY ON WHETHER WE ARE QUEUED.
  //
  // `queued` below is only optimism, to bridge the moment between pressing Play
  // and the first status arriving. Once the server has spoken, it wins.
  //
  // Believing local state indefinitely is what left players showing "Searching
  // for players..." against a server that had no record of them -- first
  // because the button was wired to nothing, and later because a match consumed
  // the queue and fell back to WAITING without the client noticing.
  const searching = lobby ? lobby.you : queued

  // When this screen is up while the match is NOT waiting, this player is in
  // the lobby during someone else's match (left it, or never readied up).
  // They can queue -- the server holds the queue until the next WAITING.
  const matchRunning = match.state !== 'waiting'

  // AM I THE ONE HOLDING THE PARTY UP? Somebody else in my party is queued
  // and I am not. The same `readyIds` the party chips already read from, so
  // the prompt above the button and the ticks beside the names can never
  // disagree about who is waiting on whom.
  const readyIds = new Set(lobby?.readyIds ?? [])
  const waitingOnMe = squad.members.length > 1
    && !searching
    && squad.members.some((m) => m.src !== squad.you && readyIds.has(m.src))

  // WHAT ARE WE WAITING FOR?
  //
  // "2 / 2 queued" was the old answer and it told the player nothing: it did
  // not say what the two were counting, whether they were part of it, or what
  // the queue was still short of. The server now sends the actual blocking
  // condition -- from the same function that decides whether to start -- and
  // this only phrases it.
  const wait = lobby?.wait

  // Readying up while the last round is still tearing down is allowed -- the
  // queue simply holds until WAITING. Saying so beats showing player counts
  // for a match that cannot form yet.
  const tearingDown = match.state === 'ended' || match.state === 'cleanup'

  // A match in progress outranks queue arithmetic: "waiting for more
  // players" while 46 of them are mid-firefight was a lie, and the counts
  // under it doubly so. Warmup is different: that door is still open and
  // the normal copy applies.
  const waitingOnMatch = matchRunning && match.state !== 'warmup' && !tearingDown

  const headline = tearingDown
    ? 'Cleaning up the last round…'
    : waitingOnMatch
      ? 'Waiting for the current match to end…'
      : wait?.reason === 'maintenance'
        ? 'Server update pending'
        : !wait
        ? 'Starting…'
        : wait.reason === 'party'
          ? 'Waiting for your party to ready up'
          : wait.reason === 'squads'
            ? `Waiting for ${wait.need - wait.have} more squad${wait.need - wait.have === 1 ? '' : 's'}`
            : `Waiting for ${wait.need - wait.have} more player${wait.need - wait.have === 1 ? '' : 's'}`

  // The supporting numbers, each one answering a question the headline
  // raises. Suppressed during teardown -- counts for a match that cannot
  // form yet only contradict the "cleaning up" headline.
  const detail: string[] = []
  if (!tearingDown && !waitingOnMatch) {
    if (lobby?.party) detail.push(`Your party ${lobby.party.ready}/${lobby.party.size} ready`)
    // "2 of 16 players needed" read as a riddle -- needed for WHAT, and am I
    // one of the 2? Say what is true in words instead. Solo queuers skip the
    // count entirely: there is no group whose progress they need to track.
    if (lobby && mode === 'squad') detail.push(`${lobby.queued} readied up · waiting for more players`)
    if (wait?.reason === 'squads') detail.push(`${wait.have} of ${wait.need} squads`)
  }

  const queue = async () => {
    // ═══ READYING UP WITH THE BOX TICKED IS ALSO AN ANSWER TO IT ═══
    //
    // Owner, 2026-09-07: "leaving the game tutorial early results in the toggle
    // still being available in the lobby - great, keep it - but readying up at
    // that point to go into tutorial again doesn't work. just sends straight to
    // normal warmup."
    //
    // It did not work because the only thing that armed the match half was the
    // LOBBY half finishing. That is right for a first-timer and wrong for
    // everybody who comes back: the toggle deliberately outlives the run (it is
    // an offer about the NEXT thing), so a player who abandoned the walkthrough
    // and wants another go has a ticked box and no way to spend it.
    //
    // ARMED HERE RATHER THAN BY THE TOGGLE ITSELF, and that distinction is the
    // whole reason the last one misfired. A ticked box is a preference and can
    // sit ticked forever; readying up is a discrete act with a moment attached.
    // Arming on the preference is what started the walkthrough for every player
    // on every match (2026-09-06).
    if (tutorialGameShown && tutorialGameOn) setTutorialGameArmed(true)

    // Optimistic, but the server is the authority -- the next state envelope
    // will correct this if the queue was refused.
    setQueued(true)
    const res = await fetchNui<{ mode: string }, { ok?: boolean }>(CB.QUEUE, { mode })
    if (res === null) setQueued(false)   // callback failed or timed out
  }

  const leave = async () => {
    setQueued(false)
    await fetchNui(CB.QUEUE_LEAVE, {})
  }

  return (
    <div
      // NO `transition-opacity` CLASS: the transition is written out below
      // because it now carries a second property with a delay on it.
      className="fixed inset-0"
      style={{
        opacity: visible ? 1 : 0,
        // ═══ INVISIBLE AND STILL CLICKABLE, WHICH IS ITS OWN BUG ═══
        //
        // Owner, 2026-09-05, during warmup: "the lobby buttons aren't visible
        // but still clickable somehow...."
        //
        // `opacity: 0` removes nothing from hit testing, and `pointer-events`
        // on this root is NOT a guard: `.interactive` (index.css) and `.btn`
        // both re-declare `pointer-events: auto` on descendants, so every
        // button in the faded menu is its own hit target regardless of what
        // their ancestor says. The lobby has been an invisible click surface
        // for as long as anything has put a cursor on screen over it -- the
        // player list and chat do it too. The walkthrough only made it routine.
        //
        // `visibility` is the property that cannot be undone from inside,
        // because it INHERITS and nothing in this subtree overrides it, and a
        // `visibility: hidden` element is not a hit target at all.
        //
        // THE DELAY IS WHAT KEEPS THE FADE. Switching visibility at the same
        // instant as opacity would make the menu pop instead of dissolving, so
        // it is held for the length of the fade on the way out and switched
        // immediately on the way in.
        visibility: visible ? 'visible' : 'hidden',
        transition: visible
          ? 'opacity 200ms linear'
          : 'opacity 200ms linear, visibility 0s linear 200ms',
        pointerEvents: visible ? 'auto' : 'none',
        // A SCRIM WEIGHTED TO THE LEFT, not a centred vignette.
        //
        // The menu lives in the left column and the right third is left clear
        // for the player's ped to stand in. A radial centred on the screen
        // dimmed exactly the part we want to show off and washed out the part
        // we want readable -- so this is a horizontal gradient that is opaque
        // where the text is and nearly clear where the character is.
        background:
          'linear-gradient(90deg, rgba(5,10,16,0.94) 0%, rgba(5,10,16,0.88) 38%,'
          + ' rgba(6,10,18,0.45) 62%, rgba(6,10,18,0.12) 100%)',
      }}
      aria-hidden={!visible}
    >
      {/* THE STREAMING BACKDROP -- the loadscreen's glow continued by other
          means. The loadscreen's manual shutdown lands on this identical
          opaque purple, so the swap is pixel-invisible; when Lua flips
          worldReady this fades OUT to the world while the menu below fades
          IN, both over 700ms. Solid colours on purpose: it is a stand-in
          for an unstreamed world, not a tint. */}
      <div
        className="absolute inset-0 pointer-events-none transition-opacity duration-700"
        style={{
          opacity: worldReady ? 0 : 1,
          background:
            'radial-gradient(ellipse at 50% 42%, rgb(14, 48, 62), rgb(6, 8, 14) 78%)',
        }}
      />
      {/* Sized with REAL dimensions (42rem = the old 35 + 20%), never
          transform: scale() -- a scaled layer rasterizes at 1x and re-blurs
          every time any child animates, which smeared every button's text
          the moment one was pressed. HeroUI's press animation (the "doppler"
          scale on the button itself) is unaffected and stays.

          Opacity rides worldReady: transparent under the loadscreen, fading
          in as the backdrop fades out. Pointer events follow -- an invisible
          menu must not be clickable. */}
      {/* THE LEFT COLUMN.
          Identity at the top, the decision in the middle, one loud action at
          the bottom -- and the right third of the screen deliberately empty,
          because that is where the player's character stands. The old centred
          card put the menu exactly where the character should be and read as a
          web modal floating over a game. */}
      {/* `page-under` when a sub-screen is up: the column recedes rather than
          sitting behind them. The locker's scrim only covers the left half
          (the right half IS the character) and the market's is lighter still,
          so without this the base menu showed through both -- two screens
          stacked instead of one navigating (user, 2026-08-09). */}
      <div
        data-tut="lobby-menu"
        className={`interactive absolute inset-y-0 left-0 w-[38rem] max-w-[62vw]
                   flex flex-col justify-center px-[3.5rem] py-[3rem]
                   transition-opacity duration-700${under ? ' page-under' : ''}`}
        style={under ? undefined : {
          opacity: worldReady ? 1 : 0,
          pointerEvents: worldReady ? 'auto' : 'none',
        }}
      >
        <div>
          {/* THE WORDMARK, AND IT IS WHY "the lobby still shows FiveM Royale"
              SURVIVED TWO ROUNDS OF BEING FIXED.

              The two halves of the name are separate text nodes either side of
              a `<br />`, so the string "FiveM Royale" does not exist anywhere in
              this file -- a repo-wide grep for the old name returns Help.tsx,
              PauseMenu.tsx, index.html and the manifests, and skips the one
              place a player actually reads it, in 4.6rem display caps, on the
              first screen of the game. It is called out here so the next sweep
              does not miss it for the same reason. */}
          <h1 className="font-display text-[4.6rem] leading-[0.9] tracking-tight">
            Blitz<br />
            <span style={{ color: 'var(--color-royale-accent)' }}>Royale</span>
          </h1>
          <p className="text-[0.95rem] text-white/40 mt-2 tracking-wide">
            Drop in. Loot up. Outlast the storm.
          </p>
        </div>

        {/* LEVEL AND XP, UNDER THE WORDMARK AND ABOVE EVERYTHING ELSE.
            It is the answer to "what did all that playing get me", and a
            progression system buried behind a menu stops motivating anybody.
            This is also where the post-match award animates, which is why it
            sits on the screen the player lands on after a match rather than
            on the verdict card that flashes past. */}
        <div className="mt-6">
          <Progress />
        </div>

        {/* MODE IS A CHOICE BETWEEN TWO THINGS, so it is two tiles rather than
            a pair of buttons in a row. The tile carries what the mode MEANS --
            "one life, 47 rivals" is the actual difference, and it was nowhere
            on the old screen. */}
        <div className="mt-8" data-tut="mode-picker">
          <div className="micro-label">Mode</div>
          <div className="flex gap-2.5 mt-2">
            {([
              { id: 'solo',  name: 'Solo',   sub: 'One life. Everyone else is a rival.' },
              { id: 'squad', name: 'Squads', sub: 'Teams of four. Revives allowed.' },
            ] as const).map((m) => (
              <button
                key={m.id}
                type="button"
                // data-tut per mode, so the walkthrough can require SQUADS
                // specifically (#261) -- the party controls it goes on to
                // explain only exist once Squads is picked.
                data-tut={`mode-${m.id}`}
                disabled={searching}
                onPointerEnter={() => { if (!searching) play('ui.hover') }}
                onClick={() => {
                  if (searching) { play('ui.error'); return }
                  play('ui.select')
                  pickMode(m.id)
                }}
                className={`plate btn flex-1 text-left px-4 py-3.5${
                  mode === m.id ? ' is-active' : ''}${searching ? ' btn--off' : ''}`}
                style={{
                  ['--plate-fill' as string]: mode === m.id
                    ? 'rgba(12,58,72,0.94)' : 'rgba(24,28,40,0.92)',
                  ['--edgec' as string]: mode === m.id
                    ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.20)',
                }}
              >
                <div
                  className="font-display text-[1.35rem] leading-none"
                  style={{ color: mode === m.id ? 'var(--color-royale-accent)' : '#ffffff' }}
                >
                  {m.name.toUpperCase()}
                </div>
                {/* Two sentences describing the mode -- prose, and it was
                    hand-typed at text-white/40, which is the literal the
                    palette tokens exist to stop. --fs holds the tile's
                    original 0.72rem so the pair does not re-wrap. */}
                <div
                  className="body-text mt-1.5"
                  style={{ ['--fs' as string]: '0.72rem', lineHeight: 1.375 }}
                >
                  {m.sub}
                </div>
              </button>
            ))}
          </div>
        </div>

        {/* A FIXED SHELF, NOT A GROWING ONE.
            Switching Solo to Squads adds the party controls, and letting the
            column grow around them shoved the wordmark up and the button down
            every time the player changed their mind (user, 2026-08-08). The
            space is reserved whether or not anything is in it, so the two
            tiles and READY UP never move -- only the contents of this box
            change. Solo simply leaves it empty.

            min-height rather than height: the party panel grows with the
            number of invitable players, and clipping that list to keep the
            layout still would be fixing the wrong thing. It is stable across
            the mode switch, which is the case that was jarring. */}
        <div className="mt-6 min-h-[13rem]">
          <PartyPanel disabled={searching} mode={mode} onBlocked={setReadyBlock} />
        </div>

        {/* THE ACTION. One object, the loudest on the screen, and the only
            thing wearing the brand colour. */}
        <div className="mt-8">
          {searching ? (
            <>
              <div className="flex items-center gap-3 mb-3">
                <Ring size={1.5} stroke={0.17} label="Searching for a match" />
                <div>
                  <div className="text-[1.05rem] text-white/80 leading-tight">{headline}</div>
                  {/* A spinner alone is indistinguishable from a queue that is
                      not working, which is exactly how this looked while the
                      button was wired to nothing. */}
                  {detail.length > 0 && (
                    <div className="text-[0.78rem] tabular-nums text-white/40 mt-0.5">
                      {detail.join(' · ')}
                    </div>
                  )}
                </div>
              </div>
              <Btn variant="default" size="lg" full cue="ui.back" onPress={leave}>
                Not ready
              </Btn>
            </>
          ) : (
            <>
              {matchRunning && (
                <p className="body-text mb-2.5">
                  {match.state === 'warmup'
                    ? 'A match is forming — ready up to jump straight in.'
                    : 'A match is in progress — ready up to join the next one.'}
                </p>
              )}

              {/* SOLO LEAVES YOUR PARTY, and it says so BEFORE the button
                  rather than as a notice afterwards (user, 2026-08-09).
                  Readying up in solo drops you out of the party server-side;
                  a player who has just spent a minute assembling one deserves
                  to know that the next click undoes it. */}
              {mode === 'solo' && squad.members.length > 1 && (
                <p
                  className="text-[0.82rem] mb-2.5 tscale"
                  style={{ color: 'var(--color-warn, #FFB020)' }}
                >
                  Playing solo will remove you from your party.
                </p>
              )}

              {/* YOUR PARTY IS WAITING. Nobody standing in a lobby knows that
                  three other people are already queued and watching the
                  counter -- and the person they are waiting on is the one who
                  cannot see it. */}
              {mode === 'squad' && waitingOnMe && (
                <p
                  className="text-[0.85rem] mb-2.5 tscale font-semibold"
                  style={{ color: 'var(--color-royale-accent)' }}
                >
                  Ready up! Your party is waiting.
                </p>
              )}

              {/* BLOCKED, AND IT SAYS WHY. Picking Create or Join is stating
                  an intention, not fulfilling it -- readying up from there
                  would queue you alone into the very squad you were in the
                  middle of building (owner, 2026-08-09). The button goes dead
                  and the line above it names what is missing. */}
              {(maintenanceBlock ?? readyBlock) && (
                <p
                  className="text-[0.82rem] mb-2.5 tscale"
                  style={{ color: 'rgba(255,255,255,0.5)' }}
                >
                  {maintenanceBlock ?? readyBlock}
                </p>
              )}
              {/* ═══ THE ONE-TIME OFFER (#261) ═══

                  A TOGGLE, DEFAULT ON, immediately above Ready up, shown only
                  while Lua says this player is being offered the guided first
                  run. Owner: "A checkbox, default on, near the Ready up
                  button", then on 2026-09-04: "Instead of a checkbox can we try
                  a toggle for the tutorial?"

                  A TOGGLE SAYS SOMETHING A CHECKBOX DOES NOT, and it is why the
                  swap is an improvement rather than a preference: a checkbox is
                  a form field you agree to, a toggle is a thing that is ON. This
                  one arrives already on, and the sentence beside it changes with
                  it, so the state is readable without knowing which way round a
                  tick means yes. */}
              {tutorialOffer && (
                <TutorialToggle
                  on={tutorialChecked}
                  onChange={setTutorialChecked}
                  label={
                    <>
                      New player tutorial —{' '}
                      <b style={{ color: 'var(--color-volts)', fontWeight: 700 }}>
                        earn 500 Volts for completing!
                      </b>
                    </>
                  }
                />
              )}

              {/* ═══ THE SECOND OFFER, AND WHEN IT ARRIVES (#261) ═══

                  Owner, 2026-09-04: "When the lobby tutorial is done, a new
                  toggle should show (on by default) that offers them an in-game
                  tutorial as well... This second toggle should show immediately
                  after they come back from the Help page, which will be more
                  seamless than appearing out of nowhere and drawing their
                  attention away from the tutorial itself."

                  SO IT IS KEYED TO A STEP, NOT TO THE END OF THE RUN. `ready`
                  is the card that begins the moment Help closes, so the toggle
                  is already sitting there when the last card appears rather
                  than popping in beside it. That is the whole of what he asked
                  for and it is why the layer publishes its step id at all.

                  IT OUTLIVES THE RUN. Once shown it stays, because it is an
                  offer about the NEXT thing and the player has to be able to
                  reach it after dismissing the card that introduced it.

                  PLACEHOLDER COPY -- the label is mine. */}
              {/* SHOWN ONLY WHILE THE OFFER STANDS. `tutorialOffer` is the
                  server's answer off the profile row -- it goes false the moment
                  somebody declines or finishes, and stays false on every future
                  connect. Owner, 2026-09-07: "after completing the tutorial and
                  going back to the lobby, the toggle is still there btw." */}
              {tutorialOffer && (tutorialStep === 'ready' || tutorialGameShown) && (
                <TutorialToggle
                  on={tutorialGameOn}
                  onChange={(v) => {
                    setTutorialGameOn(v)
                    if (v) return

                    // ═══ TURNING IT OFF IS A DECISION, AND IT IS FINAL ═══
                    //
                    // Owner, 2026-09-07: "if they've actively turned down the
                    // offer we need to save that somewhere and never offer
                    // again!" Only THIS closes the offer -- an abandoned run
                    // deliberately does not, because he asked for the toggle to
                    // survive that.
                    //
                    // AND THEY ARE TOLD WHAT IT COSTS BEFORE IT IS GONE, which
                    // is the whole reason it is a card and not a silent write:
                    // "show a card informing them that 500 Volts will only be
                    // awarded if they enable that... Also inform them the offer
                    // is only valid for their first match."
                    pushNotice({
                      text: 'The ~500 Volts~ is only awarded if you finish the '
                          + 'tutorial in your first match. Turning this off gives '
                          + 'up the offer for good.',
                      tone: 'warn',
                      key: 'tutorial.declined',
                      ms: 12000,
                    })
                    void fetchNui(CB.TUTORIAL_SET, { declined: true })
                  }}
                  label="Continue tutorial into the first match"
                />
              )}
              {/* THE SAME BUTTON, TWO JOBS. Owner: "When ticked, the box should
                  change the 'ready up' button to a 'start tutorial' button." It
                  does not queue in that state -- the walkthrough holds them in
                  the lobby, which is the whole point of it being an alternative
                  to readying up rather than a step before it. */}
              <span data-tut="ready" className="block">
                <Btn
                  variant="primary" size="xl" full cue="ui.ready"
                  // ═══ HELD WHILE THE WALKTHROUGH IS RUNNING (#261) ═══
                  //
                  // Owner, 2026-09-04: "While the tutorial is actively in
                  // progress, please grey out the 'Ready up' button and release
                  // the button once the Tutorial is complete."
                  //
                  // It is the last card's Dismiss that releases it, because
                  // `tutorialRun` is what the walkthrough sets and clears -- so
                  // the button comes back at exactly the moment the run ends,
                  // however it ended.
                  //
                  // NO EXPLANATION BESIDE IT. A disabled control with a
                  // sentence apologising for itself is worse than a disabled
                  // control, and the card on screen is already telling them
                  // what to do.
                  disabled={tutorialRun || (maintenanceBlock ?? readyBlock) != null}
                  onPress={startTutorial ? beginTutorial : queue}
                >
                  {startTutorial ? 'Start tutorial' : 'Ready up'}
                </Btn>
              </span>
            </>
          )}
        </div>

        {/* THE WAY IN TO SETTINGS. It used to be a line of text telling the
            player to go and find GTA's pause menu, which is instructions
            where a button belongs -- and there was nowhere at all to reach
            interface scale, colourblind modes or volume. */}
        {/* SECONDARY, NOT TINY. These were `sm` -- 0.72rem against READY UP's
            1.6rem -- which read as fine print rather than as the other two
            things you can do on this screen (user, 2026-08-09). They are a
            PAIR, so they split the column evenly and sit on the same line
            weight as the mode tiles above them. */}
        {/* THE THREE OTHER PLACES YOU CAN GO. Each ASKS Lua for the cursor
            rather than opening a screen locally -- the focus stack decides
            what is on screen, so there is one source of truth about it. */}
        <div className="mt-6 flex gap-2.5">
          {/* HIDDEN UNTIL LUA HAS SENT A ROSTER, rather than opening onto an
              empty list -- a screen with nothing in it reads as broken, and
              the push arrives within a frame of the interface being alive. */}
          {locker.peds.length > 0 && (
            <div className="flex-1">
              {/* LOCKED WHILE THE PED IS WALKING IN. The lobby entrance has
                  the character on an authored path and a model swap would take
                  the ped handle out from under it, so the locker is simply
                  unavailable until it arrives (owner, 2026-08-29). No
                  explanation on purpose: this is the same disabled plate every
                  other unavailable control on this screen uses. */}
              <span data-tut="locker" className="block">
                <Btn
                  variant="default" size="md" full cue="ui.select"
                  disabled={locker.locked === true}
                  onPress={() => { void fetchNui(CB.LOCKER_FOCUS, { open: true }) }}
                >
                  Locker
                </Btn>
              </span>
            </div>
          )}
          <div className="flex-1" data-tut="market">
            <Btn
              variant="default" size="md" full cue="ui.select"
              onPress={() => { void fetchNui(CB.MARKET_FOCUS, { open: true }) }}
            >
              Market
            </Btn>
          </div>
          {/* HELP BELONGS HERE TOO, not only in the pause menu. The lobby is
              where a new player stands before they have anything to pause,
              and it is the one moment they have time to read (user,
              2026-08-09). Same component, standalone frame. */}
          <div className="flex-1" data-tut="help">
            <Btn
              variant="default" size="md" full cue="ui.select"
              onPress={() => { void fetchNui(CB.HELP_FOCUS, { open: true }) }}
            >
              Help
            </Btn>
          </div>
          <div className="flex-1" data-tut="settings">
            <Btn
              variant="default" size="md" full cue="ui.select"
              onPress={() => { void fetchNui(CB.SETTINGS_FOCUS, { open: true }) }}
            >
              Settings
            </Btn>
          </div>
        </div>

        {/* NOTHING GOES UNDER THE MENU (#147). LIFTED ONCE, BY HIM, ON
            2026-08-30, AND BACK IN FORCE FROM 2026-08-31. The round trip is
            recorded at the bottom rather than erased, because a rule that has
            been tested and put back is a stronger rule than one nobody ever
            questioned -- and because the next person to want this space
            deserves to know it has already been tried.

            A LEAVE SERVER BUTTON STOOD HERE AND THE OWNER TOOK IT OUT UNDER
            #83: "the leave button shouldn't be on the front page, but rather
            in the pause menu." It was here because at the time the pause menu
            could not be opened from the lobby at all -- the game never
            receives a keypress while our cursor is up, so neither key route
            reached it. The page's own Escape handler does receive one, and it
            now asks for the menu (App.tsx), so the exit went back where it
            belongs.

            WHAT #83 LEFT BEHIND WAS A KEY HINT -- "Esc — pause menu, and the
            way to leave the server" -- on the argument that a menu nobody
            knows about is the same as no menu. The owner has now rejected that
            too (#147, 2026-08-16: "We don't need helper text under the menu in
            the lobby btw"), so the hint is gone and this comment is what is
            left of it: the reasoning was that the menu needed advertising, and
            the answer is that it does not. Escape is the pause key in every
            game the players already own, and the button below it is the thing
            this screen is for. Do not put a third thing here.

            THE THIRD THING WAS TRIED AND IS GONE AGAIN. On 2026-08-30 the
            owner was asked where the Discord card should go in the lobby --
            above this row, or below it with this note lifted -- and he chose
            below it and lifted the note himself, on the reading that what #147
            threw out was HELPER TEXT and a card with an address on it is a
            control rather than a sentence. He then played it, on 2026-08-31,
            and cut the card from this screen and from the pause menu's front
            page in the same breath: "the card in the pause menu is HUGE. we
            don't need that. Find a better place for it. Perhaps on the Help
            page only." It lives in screens/Help.tsx now, one line beside that
            page's Copy link button.

            SO THE RULE IS BACK, UNQUALIFIED, and it has been tested. The
            distinction the lift rested on was real and it was not enough: the
            problem was never whether the thing under the menu was helper text
            or a control, it was that the lobby's menu row is the end of the
            screen. Nothing goes under it.

            ONE MEASUREMENT IS WORTH KEEPING out of the day the card was here,
            because it is not about the card. This column is `absolute inset-y-0
            flex flex-col justify-center` with no overflow handling -- unlike
            the pause menu's root, which scrolls -- so a column taller than the
            viewport is centred past both edges and clips symmetrically and
            silently, top and bottom, taking the wordmark with it and saying
            nothing. Measured in the harness at a true 1280x720 (2026-08-30),
            the budget is 654px -- 720 less the 3rem top and bottom padding, at
            the 11px the root font clamps to at that height -- and a party of
            four with the invite list full, a match running and the party
            waiting on you wanted 648.6px of it WITH the 62.1px card block that
            has since gone, so roughly 586px now. The number that matters is the
            other one: with no card here at all, the column already clipped from
            an interface size of 122%. That is a pre-existing bug, it is
            unreported, and it is the real reason this space is not spare. */}
      </div>
    </div>
  )
}
