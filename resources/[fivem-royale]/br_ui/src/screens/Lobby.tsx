import { Button, Card, CardContent, CardHeader, CardTitle, Chip, Spinner } from '@heroui/react'
import { useState } from 'react'
import { useUi, selMatch, selSquad } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'

/**
 * Lobby and queue.
 *
 * This is where HeroUI earns its place: a focused, interactive, non-realtime
 * screen. The in-match HUD deliberately avoids it -- see hud/Hud.tsx.
 *
 * Mounted always, shown only when Lua has granted focus to the lobby, so the
 * transition costs no mount work.
 */
export default function Lobby({ visible }: { visible: boolean }) {
  const match = useUi(selMatch)
  const squad = useUi(selSquad)
  const [queued, setQueued] = useState(false)
  const [mode, setMode] = useState<'solo' | 'squad'>('squad')

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
        background: 'radial-gradient(ellipse at 50% 40%, rgb(20 12 40 / 0.72), rgb(6 8 14 / 0.92))',
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

        <Card>
          <CardHeader>
            <CardTitle>{warmup ? 'Match starting' : 'Find a match'}</CardTitle>
          </CardHeader>

          <CardContent className="flex flex-col gap-4">
            <div className="flex gap-2">
              {(['solo', 'squad'] as const).map((m) => (
                <Button
                  key={m}
                  variant={mode === m ? 'primary' : 'secondary'}
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
                  <Chip key={m.src} style={{ borderColor: m.colour }}>
                    {m.name}
                  </Chip>
                ))}
              </div>
            )}

            {warmup ? (
              <div className="flex items-center justify-center gap-3 py-2">
                <Spinner />
                <span className="text-sm text-white/70">Warmup &mdash; everyone drops shortly</span>
              </div>
            ) : queued ? (
              <div className="flex flex-col gap-2">
                <div className="flex items-center justify-center gap-3 py-1">
                  <Spinner />
                  <span className="text-sm text-white/70">Searching for players&hellip;</span>
                </div>
                <Button variant="secondary" onPress={leave}>Cancel</Button>
              </div>
            ) : (
              <Button variant="primary" size="lg" onPress={queue}>
                Play {mode}
              </Button>
            )}
          </CardContent>
        </Card>

        <p className="text-center text-[0.6875rem] text-white/30 mt-4">
          Rebind controls in Pause &rarr; Settings &rarr; Key Bindings
        </p>
      </div>
    </div>
  )
}
