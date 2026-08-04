import { Button, Chip } from '@heroui/react'
import { useEffect, useState } from 'react'
import { useUi, selSquad, selLobby } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'

/**
 * Party panel.
 *
 * A PARTY is a persistent group of friends; a SQUAD is the in-match team formed
 * from parties plus autofilled solo players. This panel operates on the party,
 * which is why it survives a match ending.
 *
 * Invites are made by PICKING FROM A LIST, not by typing a server id. The first
 * version asked for an id, which nothing in the game shows you -- so there was
 * no way to invite anyone you had not separately arranged it with.
 *
 * The server is the authority: this asks to invite, accept, decline, leave or
 * remove. Everything shown comes from state the server pushed.
 */
export default function PartyPanel({
  disabled,
  mode,
}: {
  disabled: boolean
  mode: 'solo' | 'squad'
}) {
  const squad = useUi(selSquad)
  const lobby = useUi(selLobby)
  const invite = useUi((s) => s.invite)
  const clearInvite = useUi((s) => s.clearInvite)

  const [selected, setSelected] = useState<Set<number>>(new Set())

  // How this player wants to end up in a squad: build one (invite people),
  // knock on one (ask a leader), or let autofill sort it out. Only shown
  // before a party exists -- once in one, the party itself is the answer.
  const [subMode, setSubMode] = useState<'create' | 'join' | 'random'>('create')

  const inParty = squad.members.length > 1

  // Whether *I* am the leader, which needs my own server id -- Lua sends it,
  // because the interface has no other way to know it. The previous check asked
  // whether the party HAS a leader, which is true for every member, so everyone
  // saw invite controls the server would then refuse.
  const iAmLeader = !squad.id || (squad.you != null && squad.leader === squad.you)

  const players = lobby?.players ?? []

  // Anyone already in a party cannot be invited into another, so offering them
  // would only produce a rejection. Anyone we have ALREADY invited shows as a
  // pending chip instead -- listing them here too would invite double-sends.
  const pendingSrcs = new Set((squad.pending ?? []).map((p) => p.src))
  const invitable = players.filter(
    (p) => !p.inParty && !p.inMatch && !pendingSrcs.has(p.src))

  // The Join tab's targets: leaders of real parties who are not mid-match.
  const leaders = players.filter((p) => p.leader && !p.inMatch)

  // Drop selections that are no longer valid -- a player who disconnected, or
  // who joined someone else's party while the panel was open.
  useEffect(() => {
    setSelected((prev) => {
      const valid = new Set(invitable.map((p) => p.src))
      const next = new Set([...prev].filter((s) => valid.has(s)))
      return next.size === prev.size ? prev : next
    })
  }, [players])

  const toggle = (src: number) => {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(src)) next.delete(src)
      else next.add(src)
      return next
    })
  }

  const inviteSelected = async () => {
    const targets = [...selected]
    setSelected(new Set())
    // One call per invite: the server validates each independently, so a full
    // party or a player who just left fails only that one.
    for (const target of targets) {
      await fetchNui(CB.SQUAD_INVITE, { target })
    }
  }

  const respond = async (accept: boolean) => {
    const wasJoinReq = invite?.kind === 'joinreq'
    const requester = invite?.from
    clearInvite()
    // Same card, two directions: an invite is answered by the invitee, a
    // join request by the leader it was sent to.
    if (wasJoinReq) {
      await fetchNui(CB.SQUAD_JOINRESP, { requester, accept })
    } else {
      await fetchNui(CB.SQUAD_RESPOND, { accept })
    }
  }

  const askToJoin = async (leader: number) => {
    await fetchNui(CB.SQUAD_JOINREQ, { leader })
  }

  return (
    <div className="flex flex-col gap-2">
      {/* An incoming invite outranks everything else here: it expires, so it
          must not be something you have to go looking for. */}
      {invite && (
        <div className="rise flex items-center gap-2 rounded-lg border border-white/20 px-3 py-2">
          <span className="flex-1 text-xl">
            <span className="font-semibold">{invite.name}</span>
            <span className="text-white/60">
              {invite.kind === 'joinreq' ? ' wants to join your party' : ' invited you'}
            </span>
            <span className="text-white/40 text-[1rem]">
{' '}({invite.size}/{invite.max})
            </span>
          </span>
          <Button size="sm" color="primary" onPress={() => respond(true)}>Accept</Button>
          <Button size="sm" variant="bordered" onPress={() => respond(false)}>Decline</Button>
        </div>
      )}

      {/* No solo branch: choosing Solo LEAVES the party (Lobby.pickMode + the
          server-side guard on queue), so there is never a party to explain
          under a Solo selection -- by design, not omission. */}
      {mode === 'squad' && (inParty ? (
        <div className="flex flex-wrap items-center gap-1.5">
          {squad.members.map((m) => {
            // Once ANYBODY in the party readies up, show who the group is
            // still waiting on -- a party where three are queued and one is
            // browsing settings was previously indistinguishable from a
            // party where nobody had pressed the button.
            const readyIds = new Set(lobby?.readyIds ?? [])
            const someoneReady = squad.members.some((x) => readyIds.has(x.src))
            const ready = readyIds.has(m.src)
            return (
              <Chip
                key={m.src}
                size="sm"
                variant="bordered"
                className={someoneReady && !ready ? 'opacity-55' : undefined}
                style={{ borderColor: m.colour }}
                title={
                  someoneReady
                    ? ready ? 'Readied up' : 'Not readied up yet'
                    : m.leader ? 'Party leader' : undefined
                }
              >
                {m.leader ? '★ ' : ''}{m.name}
                {someoneReady && (
                  <span
                    className="ml-1 text-[0.78rem]"
                    style={{ color: ready ? 'var(--color-hp)' : 'rgba(255,255,255,0.4)' }}
                  >
                    {ready ? '✓' : '…'}
                  </span>
                )}
              </Chip>
            )
          })}

          {/* Invites still out. Without these, "Invite sent" faded after four
              seconds and an ignored invite looked identical to one that was
              never sent. Dashed border + pulse = live and waiting; the chip
              resolves into a member, a decline notice, or an expiry notice,
              so the animation always has an ending. */}
          {(squad.pending ?? []).map((p) => (
            <Chip
              key={`pending-${p.src}`}
              size="sm"
              variant="bordered"
              className="border-dashed opacity-70 animate-pulse"
              title={`Waiting for ${p.name} to answer`}
            >
              {p.name} &hellip;
            </Chip>
          ))}
        </div>
      ) : (
        <>
          {/* Not in a party yet: pick HOW to get one. */}
          <div className="flex gap-1.5">
            {(['create', 'join', 'random'] as const).map((sm) => (
              <Button
                key={sm}
                size="sm"
                color={subMode === sm ? 'primary' : 'default'}
                variant={subMode === sm ? 'solid' : 'bordered'}
                isDisabled={disabled}
                onPress={() => setSubMode(sm)}
                className="flex-1 capitalize"
              >
                {sm}
              </Button>
            ))}
          </div>

          {subMode === 'random' && (
            <p className="text-[1rem] text-white/35">
              You&rsquo;ll be matched with random teammates.
            </p>
          )}

          {subMode === 'join' && !disabled && (
            leaders.length > 0 ? (
              <div className="flex flex-col gap-1.5">
                <span className="text-[0.9375rem] uppercase tracking-wider text-white/35">
                  Squads looking for players &mdash; ask to join
                </span>
                <div className="thin-scroll flex flex-wrap gap-1.5 max-h-24 overflow-y-auto">
                  {leaders.map((p) => (
                    <button
                      key={p.src}
                      type="button"
                      onClick={() => void askToJoin(p.src)}
                      className="rounded-full border border-white/15 px-2.5 py-1 text-[1.0625rem]
                                 text-white/70 hover:border-white/35 transition-colors"
                      title={`Ask to join ${p.name}'s squad`}
                    >
                      ★ {p.name}
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              <p className="text-[1rem] text-white/35">
                No open squads to join right now.
              </p>
            )
          )}
        </>
      ))}

      {/* The player list -- the CREATE flow. Only shown when there is
          somebody to invite, so an empty server does not display an empty
          box; also shown while already leading a party (inviting more). */}
      {mode === 'squad' && (inParty || subMode === 'create')
        && !disabled && iAmLeader && invitable.length > 0 && (
        <div className="flex flex-col gap-1.5">
          <span className="text-[0.9375rem] uppercase tracking-wider text-white/35">
            Players online &mdash; select to invite
          </span>

          <div className="thin-scroll flex flex-wrap gap-1.5 max-h-24 overflow-y-auto">
            {invitable.map((p) => {
              const on = selected.has(p.src)
              return (
                <button
                  key={p.src}
                  type="button"
                  onClick={() => toggle(p.src)}
                  className={
                    'rounded-full border px-2.5 py-1 text-[1.0625rem] transition-colors ' +
                    (on
                      ? 'border-primary bg-primary/25 text-white'
                      : 'border-white/15 text-white/70 hover:border-white/35')
                  }
                >
                  {on ? '✓ ' : ''}{p.name}
                  {p.queued && <span className="text-white/35 text-[0.625rem]"> · queued</span>}
                </button>
              )
            })}
          </div>

          <Button
            size="sm"
            variant="bordered"
            isDisabled={selected.size === 0}
            onPress={inviteSelected}
          >
            {selected.size === 0
              ? 'Select players to invite'
              : `Invite ${selected.size} player${selected.size === 1 ? '' : 's'}`}
          </Button>
        </div>
      )}

      {/* Leaving must be obvious and always available. A party you cannot get
          out of is worse than no party system. */}
      {mode === 'squad' && inParty && (
        <Button size="sm" variant="bordered" onPress={() => fetchNui(CB.SQUAD_LEAVE, {})}>
          Leave party
        </Button>
      )}

    </div>
  )
}
