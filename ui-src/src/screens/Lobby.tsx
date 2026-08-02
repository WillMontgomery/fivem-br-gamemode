import { Button, Card, CardBody, CardHeader, Chip, Spinner } from '@heroui/react'
import { useState } from 'react'
import { useUi, selMatch, selSquad, selLobby } from '../store'
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
  const squad = useUi(selSquad)
  const lobby = useUi(selLobby)
  const [queued, setQueued] = useState(false)
  const [mode, setMode] = useState<'solo' | 'squad'>('squad')

  // The server is the authority on whether we are queued. Believing only local
  // state meant the button showed "Searching..." forever while the server had
  // no idea we existed -- which is precisely what happened when the queue
  // callback was wired to an event nobody handled.
  const serverQueued = (lobby?.queued ?? 0) > 0
  const short = lobby ? Math.max(0, lobby.needed - lobby.queued) : 0

  const warmup = match.state === 'warmup'

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
                  isDisabled={queued || warmup}
                  onPress={() => setMode(m)}
                  className="flex-1 capitalize"
                >
                  {m}
                </Button>
              ))}
            </div>

            {squad.members.length > 0 && (
              <div className="flex flex-wrap gap-1.5">
                {squad.members.map((m) => (
                  <Chip
                    key={m.src}
                    size="sm"
                    variant="bordered"
                    style={{ borderColor: m.colour }}
                  >
                    {m.name}
                  </Chip>
                ))}
              </div>
            )}

            {warmup ? (
              <div className="flex items-center justify-center gap-3 py-2">
                <Spinner size="sm" />
                <span className="text-sm text-white/70">
                  Warmup &mdash; everyone drops shortly
                </span>
              </div>
            ) : queued ? (
              <div className="flex flex-col gap-2">
                <div className="flex flex-col items-center gap-1 py-1">
                  <div className="flex items-center gap-3">
                    <Spinner size="sm" />
                    <span className="text-sm text-white/70">
                      {short > 0
                        ? `Waiting for ${short} more player${short === 1 ? '' : 's'}`
                        : 'Starting…'}
                    </span>
                  </div>

                  {/* The actual numbers. "Searching for players" on its own is
                      indistinguishable from a queue that is not working, which
                      is exactly how this looked while the button did nothing. */}
                  {lobby && (
                    <span className="text-[0.6875rem] tabular-nums text-white/40">
                      {lobby.queued} / {lobby.needed} queued
                      {lobby.connected > lobby.queued &&
                        ` · ${lobby.connected} connected`}
                    </span>
                  )}

                  {/* If the server does not think we are queued, say so rather
                      than spinning forever. */}
                  {lobby && !serverQueued && (
                    <span className="text-[0.6875rem] text-danger">
                      Server has not registered the queue
                    </span>
                  )}
                </div>
                <Button variant="bordered" onPress={leave}>Cancel</Button>
              </div>
            ) : (
              <Button color="primary" size="lg" onPress={queue} className="capitalize">
                Play {mode}
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
