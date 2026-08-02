import { Button, Chip, Input } from '@heroui/react'
import { useState } from 'react'
import { useUi, selSquad } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'

/**
 * Party panel.
 *
 * A PARTY is a persistent group of friends; a SQUAD is the in-match team formed
 * from parties plus autofilled solo players. This panel operates on the party,
 * which is why it survives a match ending.
 *
 * The server is the authority: this can ask to invite, accept, decline, leave
 * or remove. It never asserts membership -- everything shown comes from a
 * SQUAD_UPDATE the server pushed to party members only.
 */
export default function PartyPanel({ disabled }: { disabled: boolean }) {
  const squad = useUi(selSquad)
  const invite = useUi((s) => s.invite)
  const clearInvite = useUi((s) => s.clearInvite)
  const [target, setTarget] = useState('')

  const inParty = squad.members.length > 1
  const me = squad.members.find((m) => m.leader)
  const iAmLeader = squad.members.some((m) => m.leader && m.src === squad.leader)

  const doInvite = async () => {
    const id = parseInt(target, 10)
    if (!Number.isFinite(id)) return
    setTarget('')
    await fetchNui(CB.SQUAD_INVITE, { target: id })
  }

  const respond = async (accept: boolean) => {
    clearInvite()
    await fetchNui(CB.SQUAD_RESPOND, { accept })
  }

  return (
    <div className="flex flex-col gap-2">
      {/* An incoming invite outranks everything else on this panel: it expires,
          so it must not be something you have to go looking for. */}
      {invite && (
        <div className="rise flex items-center gap-2 rounded-lg border border-white/15 px-3 py-2">
          <span className="flex-1 text-sm">
            <span className="font-semibold">{invite.name}</span>
            <span className="text-white/60"> invited you</span>
            <span className="text-white/40 text-[0.6875rem]">
              {' '}({invite.size}/{invite.max})
            </span>
          </span>
          <Button size="sm" color="primary" onPress={() => respond(true)}>
            Accept
          </Button>
          <Button size="sm" variant="bordered" onPress={() => respond(false)}>
            Decline
          </Button>
        </div>
      )}

      {inParty ? (
        <>
          <div className="flex flex-wrap items-center gap-1.5">
            {squad.members.map((m) => (
              <Chip
                key={m.src}
                size="sm"
                variant="bordered"
                style={{ borderColor: m.colour }}
                title={m.leader ? 'Party leader' : undefined}
              >
                {m.leader ? '★ ' : ''}{m.name}
              </Chip>
            ))}
          </div>

          <div className="flex gap-2">
            {/* Leaving must be obvious and always available. A party you cannot
                get out of is worse than no party system. */}
            <Button
              size="sm"
              variant="bordered"
              className="flex-1"
              onPress={() => fetchNui(CB.SQUAD_LEAVE, {})}
            >
              Leave party
            </Button>
          </div>
        </>
      ) : (
        <p className="text-[0.6875rem] text-white/35">
          Not in a party &mdash; you&rsquo;ll be matched with random teammates.
        </p>
      )}

      {/* Invite by server id. Crude, and honest about it: a friends list needs
          persistent identity, which arrives with the stats layer. */}
      {!disabled && (!inParty || iAmLeader || !me) && (
        <div className="flex gap-2">
          <Input
            size="sm"
            value={target}
            onValueChange={setTarget}
            placeholder="Player ID"
            className="flex-1"
            onKeyDown={(e) => { if (e.key === 'Enter') void doInvite() }}
          />
          <Button size="sm" variant="bordered" onPress={doInvite} isDisabled={!target}>
            Invite
          </Button>
        </div>
      )}
    </div>
  )
}
