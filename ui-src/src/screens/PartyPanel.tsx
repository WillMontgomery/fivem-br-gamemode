import Btn from '../ui/Btn'
import { play } from '../audio/cues'
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
  const [subMode, setSubMode] = useState<'create' | 'join' | 'random'>('random')

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

  // WHY SOMEBODY IS NOT INVITABLE IS NOW PART OF THE LIST.
  //
  // This used to be a filter, and the section was hidden entirely when it came
  // back empty -- so "there is somebody else in this lobby and I cannot invite
  // them" showed up as no list at all, with nothing to say whether they were
  // in a party, in a match, or whether the feature was simply broken (user,
  // 2026-08-09). Everyone connected is listed; the ones who cannot be picked
  // say what is stopping them.
  const listed = players
    .filter((p) => p.src !== squad.you && !pendingSrcs.has(p.src))
    .map((p) => ({
      ...p,
      blocked: p.inParty ? 'in a party' : p.inMatch ? 'in a match' : null,
    }))
  const invitable = listed.filter((p) => !p.blocked)

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
        <div className="rise plate flex items-center gap-2 px-3 py-2"
             style={{ ['--edgec' as string]: 'var(--color-royale-accent)',
                      ['--plate-fill' as string]: 'rgba(10,44,56,0.94)' }}>
          <span className="flex-1 text-[0.95rem]">
            <span className="font-semibold">{invite.name}</span>
            <span className="text-white/60">
              {invite.kind === 'joinreq' ? ' wants to join your party' : ' invited you'}
            </span>
            <span className="text-white/40 text-[0.8rem]">
{' '}({invite.size}/{invite.max})
            </span>
          </span>
          <Btn size="sm" variant="primary" onPress={() => respond(true)}>Accept</Btn>
          <Btn size="sm" variant="ghost" cue="ui.back" onPress={() => respond(false)}>Decline</Btn>
        </div>
      )}

      {/* INVITES YOU HAVE SENT, WHOEVER YOU ARE.
          These used to live inside the in-a-party branch, which meant the one
          person who most needs them -- someone inviting their first friend, so
          still a party of one -- never saw them at all. An invite that has been
          sent and an invite that failed to send looked identical (user,
          2026-08-08).

          A chip resolves one of three ways and the animation always has an
          ending: into a member when they accept, or into a notice when they
          decline or it expires. */}
      {mode === 'squad' && (squad.pending ?? []).length > 0 && !inParty && (
        <div>
          <div className="micro-label mb-1.5">Invites sent</div>
          <div className="flex flex-wrap gap-1.5">
            {(squad.pending ?? []).map((p) => (
              <span
                key={`out-${p.src}`}
                className="plate px-2.5 py-1 text-[0.72rem] font-semibold
                           flex items-center gap-1.5 animate-pulse"
                style={{
                  ['--edgec' as string]: 'var(--color-royale-accent)',
                  ['--plate-fill' as string]: 'rgba(10,44,56,0.9)',
                  ['--cut-max' as string]: '0.4rem',
                }}
                title={`Waiting for ${p.name} to answer`}
              >
                {p.name}
                <span style={{ color: 'var(--color-royale-accent)' }}>…</span>
              </span>
            ))}
          </div>
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
              <span
                key={m.src}
                className={`plate px-2.5 py-1 text-[0.72rem] font-semibold
                  flex items-center gap-1.5 ${someoneReady && !ready ? 'opacity-55' : ''}`}
                style={{ ['--edgec' as string]: m.colour,
                         ['--plate-fill' as string]: 'rgba(26,30,42,0.94)',
                         ['--cut-max' as string]: '0.4rem' }}
                title={
                  someoneReady
                    ? ready ? 'Readied up' : 'Not readied up yet'
                    : m.leader ? 'Party leader' : undefined
                }
              >
                {m.leader ? '★ ' : ''}{m.name}
                {someoneReady && (
                  // THE TICK LANDS, it does not appear. `key={ready}` remounts
                  // the span on the transition, so the punch animation replays
                  // exactly once per player readying up -- which is the moment
                  // worth noticing on a screen where everything else is still
                  // (owner's call, 2026-08-09). The waiting state gets no
                  // animation at all: it is the absence of news.
                  <span
                    key={String(ready)}
                    className="ml-1 text-[0.78rem] leading-none"
                    style={{
                      color: ready ? 'var(--color-hp)' : 'rgba(255,255,255,0.4)',
                      animation: ready ? 'punch 380ms var(--ease-out) both' : undefined,
                      display: 'inline-block',
                    }}
                  >
                    {ready ? '✓' : '…'}
                  </span>
                )}

                {/* REMOVE, and only the leader sees it. It is a `×` on the
                    chip rather than a row in a menu because the chip IS the
                    member -- there is nowhere else for it to live that would
                    not need a second list of the same people. */}
                {iAmLeader && m.src !== squad.you && !disabled && (
                  <button
                    type="button"
                    data-plain
                    className="ml-0.5 text-[0.72rem] leading-none"
                    style={{ color: 'rgba(255,255,255,0.35)' }}
                    title={`Remove ${m.name} from the party`}
                    onClick={() => {
                      play('ui.back')
                      void fetchNui(CB.SQUAD_KICK, { target: m.src })
                    }}
                  >
                    &times;
                  </button>
                )}
              </span>
            )
          })}

          {/* Invites still out. Without these, "Invite sent" faded after four
              seconds and an ignored invite looked identical to one that was
              never sent. Dashed border + pulse = live and waiting; the chip
              resolves into a member, a decline notice, or an expiry notice,
              so the animation always has an ending. */}
          {(squad.pending ?? []).map((p) => (
            <span
              key={`pending-${p.src}`}
              className="plate px-2.5 py-1 text-[0.72rem] font-semibold opacity-60 animate-pulse"
              style={{
                ['--edgec' as string]: 'rgba(255,255,255,0.25)',
                ['--plate-fill' as string]: 'rgba(20,24,34,0.9)',
                ['--cut-max' as string]: '0.4rem',
              }}
              title={`Waiting for ${p.name} to answer`}
            >
              {p.name} &hellip;
            </span>
          ))}
        </div>
      ) : (
        <>
          {/* Not in a party yet: pick HOW to get one. Three plates in a row,
              the selected one bevelled -- the same "this is the chosen one"
              language the mode tiles and the inventory use. */}
          <div className="flex gap-1.5">
            {(['create', 'join', 'random'] as const).map((sm) => (
              <Btn
                key={sm}
                size="lg"
                variant={subMode === sm ? 'primary' : 'default'}
                active={subMode === sm}
                disabled={disabled}
                full
                onPress={() => setSubMode(sm)}
              >
                {sm}
              </Btn>
            ))}
          </div>

          {subMode === 'random' && (
            <p className="micro-label">
              You&rsquo;ll be matched with random teammates.
            </p>
          )}

          {subMode === 'join' && !disabled && (
            leaders.length > 0 ? (
              <div className="flex flex-col gap-1.5">
                <span className="micro-label">
                  Squads looking for players &mdash; ask to join
                </span>
                <div className="thin-scroll flex flex-wrap gap-1.5 max-h-24 overflow-y-auto">
                  {leaders.map((p) => (
                    <button
                      key={p.src}
                      type="button"
                      onClick={() => void askToJoin(p.src)}
                      className="plate btn px-2.5 py-1 text-[0.78rem] font-semibold"
                      style={{ ['--edgec' as string]: 'rgba(255,255,255,0.22)',
                               ['--plate-fill' as string]: 'rgba(26,30,42,0.94)',
                               ['--cut-max' as string]: '0.4rem' }}
                      onPointerEnter={() => play('ui.hover')}
                      title={`Ask to join ${p.name}'s squad`}
                    >
                      ★ {p.name}
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              <p className="micro-label">
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
        && !disabled && iAmLeader && (
        <div className="flex flex-col gap-1.5">
          <span className="micro-label">
            Players online &mdash; select to invite
          </span>

          {/* NOT HIDDEN WHEN EMPTY. An absent list and a list with nobody in
              it look identical, and only one of them is a working feature. */}
          {listed.length === 0 && (
            <p className="micro-label" style={{ textTransform: 'none' }}>
              Nobody else is connected right now.
            </p>
          )}

          <div className="thin-scroll flex flex-wrap gap-1.5 max-h-24 overflow-y-auto">
            {listed.map((p) => {
              const on = selected.has(p.src)
              return (
                <button
                  key={p.src}
                  type="button"
                  disabled={p.blocked != null}
                  onClick={() => { if (!p.blocked) toggle(p.src) }}
                  className={`plate btn px-2.5 py-1 text-[0.78rem] font-semibold${on ? ' is-active' : ''}`}
                  style={{
                    ['--edgec' as string]: on ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.22)',
                    ['--plate-fill' as string]: on ? 'rgba(10,44,56,0.94)' : 'rgba(26,30,42,0.94)',
                    ['--cut-max' as string]: '0.4rem',
                    opacity: p.blocked ? 0.45 : 1,
                  }}
                  onPointerEnter={() => { if (!p.blocked) play('ui.hover') }}
                  title={p.blocked ? `${p.name} is ${p.blocked}` : undefined}
                >
                  {on ? '✓ ' : ''}{p.name}
                  {p.blocked
                    ? <span className="text-white/35 text-[0.625rem]"> · {p.blocked}</span>
                    : p.queued && <span className="text-white/35 text-[0.625rem]"> · queued</span>}
                </button>
              )
            })}
          </div>

          <Btn
            size="md"
            variant={selected.size === 0 ? 'default' : 'primary'}
            disabled={selected.size === 0}
            full
            onPress={inviteSelected}
          >
            {selected.size === 0
              ? 'Select players to invite'
              : `Invite ${selected.size} player${selected.size === 1 ? '' : 's'}`}
          </Btn>
        </div>
      )}

      {/* Leaving must be obvious and always available. A party you cannot get
          out of is worse than no party system. */}
      {mode === 'squad' && inParty && (
        <Btn size="md" variant="danger" cue="ui.back" full
             onPress={() => fetchNui(CB.SQUAD_LEAVE, {})}>
          Leave party
        </Btn>
      )}

    </div>
  )
}
