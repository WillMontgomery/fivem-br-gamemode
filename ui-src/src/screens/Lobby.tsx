import { Button, Card, CardBody, CardHeader, Spinner } from '@heroui/react'
import { useState } from 'react'
import { useUi, selMatch, selLobby } from '../store'
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
  const [queued, setQueued] = useState(false)
  const [mode, setMode] = useState<'solo' | 'squad'>('squad')

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

  const warmup = match.state === 'warmup'

  // WHAT ARE WE WAITING FOR?
  //
  // "2 / 2 queued" was the old answer and it told the player nothing: it did
  // not say what the two were counting, whether they were part of it, or what
  // the queue was still short of. The server now sends the actual blocking
  // condition -- from the same function that decides whether to start -- and
  // this only phrases it.
  const wait = lobby?.wait
  const headline = !wait
    ? 'Starting…'
    : wait.reason === 'squads'
      ? `Waiting for ${wait.need - wait.have} more squad${wait.need - wait.have === 1 ? '' : 's'}`
      : `Waiting for ${wait.need - wait.have} more player${wait.need - wait.have === 1 ? '' : 's'}`

  // The supporting numbers, each one answering a question the headline raises.
  const detail: string[] = []
  if (lobby?.party) detail.push(`Your party ${lobby.party.ready}/${lobby.party.size} ready`)
  if (lobby) detail.push(`${lobby.queued} of ${lobby.needed} players needed`)
  if (wait?.reason === 'squads') detail.push(`${wait.have} of ${wait.need} squads`)

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
      <div className="interactive w-[35rem] max-w-[80vw]">
        <div className="text-center mb-6">
          <h1 className="text-4xl font-bold tracking-tight">
            FiveM <span style={{ color: 'var(--color-royale-accent)' }}>Royale</span>
          </h1>
          <p className="text-sm text-white/45 mt-1">
            Drop in. Loot up. Outlast the storm.
          </p>
        </div>

        <Card className="border border-white/10">
          <CardHeader className="pb-0">
            <h2 className="text-lg font-semibold">
              {warmup ? 'Match starting' : 'Find a match'}
            </h2>
          </CardHeader>

          <CardBody className="flex flex-col gap-4">
            <div className="flex gap-2">
              {(['solo', 'squad'] as const).map((m) => (
                <Button
                  key={m}
                  color={mode === m ? 'primary' : 'default'}
                  variant={mode === m ? 'solid' : 'bordered'}
                  isDisabled={searching || warmup}
                  onPress={() => setMode(m)}
                  className="flex-1 capitalize"
                >
                  {m}
                </Button>
              ))}
            </div>

            {/* Parties persist between matches, so this is always relevant --
                not only while queueing. It knows the mode because a party has
                no meaning in solo. */}
            <PartyPanel disabled={searching || warmup} mode={mode} />

            {warmup ? (
              <div className="flex items-center justify-center gap-3 py-2">
                <Spinner size="sm" />
                <span className="text-sm text-white/70">
                  Warmup &mdash; everyone drops shortly
                </span>
              </div>
            ) : searching ? (
              <div className="flex flex-col gap-2">
                <div className="flex flex-col items-center gap-1 py-1">
                  <div className="flex items-center gap-3">
                    <Spinner size="sm" />
                    <span className="text-sm text-white/70">{headline}</span>
                  </div>

                  {/* The supporting numbers. A spinner on its own is
                      indistinguishable from a queue that is not working, which
                      is exactly how this looked while the button did nothing. */}
                  {detail.length > 0 && (
                    <span className="text-[0.6875rem] tabular-nums text-white/40">
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

        <p className="text-center text-[0.6875rem] text-white/30 mt-4">
          Rebind controls in Pause &rarr; Settings &rarr; Key Bindings
        </p>
      </div>
    </div>
  )
}
