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
  const [queued, setQueued] = useState(false)
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
      className="fixed inset-0 transition-opacity duration-200"
      style={{
        opacity: visible ? 1 : 0,
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
        className={`interactive absolute inset-y-0 left-0 w-[38rem] max-w-[62vw]
                   flex flex-col justify-center px-[3.5rem] py-[3rem]
                   transition-opacity duration-700${under ? ' page-under' : ''}`}
        style={under ? undefined : {
          opacity: worldReady ? 1 : 0,
          pointerEvents: worldReady ? 'auto' : 'none',
        }}
      >
        <div>
          <h1 className="font-display text-[4.6rem] leading-[0.9] tracking-tight">
            FiveM<br />
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
        <div className="mt-8">
          <div className="micro-label">Mode</div>
          <div className="flex gap-2.5 mt-2">
            {([
              { id: 'solo',  name: 'Solo',   sub: 'One life. Everyone else is a rival.' },
              { id: 'squad', name: 'Squads', sub: 'Teams of four. Revives allowed.' },
            ] as const).map((m) => (
              <button
                key={m.id}
                type="button"
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
                <div className="text-[0.72rem] text-white/40 mt-1.5 leading-snug">{m.sub}</div>
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
          <PartyPanel disabled={searching} mode={mode} />
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
                <p className="text-[0.8rem] text-white/40 mb-2.5">
                  {match.state === 'warmup'
                    ? 'A match is forming — ready up to jump straight in.'
                    : 'A match is in progress — ready up to join the next one.'}
                </p>
              )}
              <Btn variant="primary" size="xl" full cue="ui.ready" onPress={queue}>
                Ready up
              </Btn>
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
              <Btn
                variant="default" size="md" full cue="ui.select"
                onPress={() => { void fetchNui(CB.LOCKER_FOCUS, { open: true }) }}
              >
                Locker
              </Btn>
            </div>
          )}
          <div className="flex-1">
            <Btn
              variant="default" size="md" full cue="ui.select"
              onPress={() => { void fetchNui(CB.MARKET_FOCUS, { open: true }) }}
            >
              Market
            </Btn>
          </div>
          <div className="flex-1">
            <Btn
              variant="default" size="md" full cue="ui.select"
              onPress={() => { void fetchNui(CB.SETTINGS_FOCUS, { open: true }) }}
            >
              Settings
            </Btn>
          </div>
        </div>
      </div>
    </div>
  )
}
