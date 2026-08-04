import { Button, Card, CardBody, CardHeader, Spinner } from '@heroui/react'
import { useEffect, useRef, useState } from 'react'
import { useUi, selMatch, selLobby, selSquad } from '../store'
import PartyPanel from './PartyPanel'
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
export default function Lobby({ visible }: { visible: boolean }) {
  const match = useUi(selMatch)
  const lobby = useUi(selLobby)
  const squad = useUi(selSquad)
  const [queued, setQueued] = useState(false)
  const [mode, setMode] = useState<'solo' | 'squad'>('squad')

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
    // Solo and a party cannot coexist; picking solo leaves the party, now.
    // The server enforces the same rule on queue -- this just makes the
    // consequence visible at the moment of choice instead of at Ready up.
    if (m === 'solo' && inParty) void fetchNui(CB.SQUAD_LEAVE, {})
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
      className="fixed inset-0 flex items-center justify-center transition-opacity duration-200"
      style={{
        opacity: visible ? 1 : 0,
        pointerEvents: visible ? 'auto' : 'none',
        background:
          'radial-gradient(ellipse at 50% 40%, rgba(20, 12, 40, 0.72), rgba(6, 8, 14, 0.94))',
      }}
      aria-hidden={!visible}
    >
      {/* scale(1.2) grows the WHOLE menu 20% (user call); the text classes
          inside are additionally ~25% up, netting text at ~150% of the old
          size while the chrome stays at 120%. */}
      <div
        className="interactive w-[35rem] max-w-[80vw]"
        style={{ transform: 'scale(1.2)', transformOrigin: 'center' }}
      >
        <div className="text-center mb-6">
          <h1 className="text-6xl font-bold tracking-tight">
            FiveM <span style={{ color: 'var(--color-royale-accent)' }}>Royale</span>
          </h1>
          <p className="text-xl text-white/45 mt-1">
            Drop in. Loot up. Outlast the storm.
          </p>
        </div>

        <Card className="border border-white/10">
          <CardHeader className="pb-0 flex-col items-start gap-1">
            <h2 className="text-2xl font-semibold">
              {matchRunning ? 'Next match' : 'Find a match'}
            </h2>
            {/* Only ever seen by a player who is OUT of the running match --
                a participant never has this screen up. During warmup the door
                is still open: readying up joins THIS match, not the next. */}
            {matchRunning && (
              <p className="text-[1rem] text-white/40">
                {match.state === 'warmup'
                  ? 'A match is forming — ready up to jump straight in.'
                  : 'A match is in progress — ready up to join the next one.'}
              </p>
            )}
          </CardHeader>

          <CardBody className="flex flex-col gap-4">
            <div className="flex gap-2">
              {(['solo', 'squad'] as const).map((m) => (
                <Button
                  key={m}
                  color={mode === m ? 'primary' : 'default'}
                  variant={mode === m ? 'solid' : 'bordered'}
                  isDisabled={searching}
                  onPress={() => pickMode(m)}
                  className="flex-1 capitalize"
                >
                  {m}
                </Button>
              ))}
            </div>

            {/* Parties persist between matches, so this is always relevant --
                not only while queueing. It knows the mode because a party has
                no meaning in solo. */}
            <PartyPanel disabled={searching} mode={mode} />

            {searching ? (
              <div className="flex flex-col gap-2">
                <div className="flex flex-col items-center gap-1 py-1">
                  <div className="flex items-center gap-3">
                    <Spinner size="sm" />
                    <span className="text-xl text-white/70">{headline}</span>
                  </div>

                  {/* The supporting numbers. A spinner on its own is
                      indistinguishable from a queue that is not working, which
                      is exactly how this looked while the button did nothing. */}
                  {detail.length > 0 && (
                    <span className="text-[1rem] tabular-nums text-white/40">
                      {detail.join(' · ')}
                    </span>
                  )}
                </div>
                <Button variant="bordered" onPress={leave}>Not ready</Button>
              </div>
            ) : (
              <Button color="primary" size="lg" onPress={queue}>
                Ready up
              </Button>
            )}
          </CardBody>
        </Card>

        <p className="text-center text-[1rem] text-white/30 mt-4">
          Rebind controls in Pause &rarr; Settings &rarr; Key Bindings
        </p>
      </div>
    </div>
  )
}
