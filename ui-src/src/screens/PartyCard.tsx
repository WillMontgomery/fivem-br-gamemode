import { useUi, selSquad } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'

/**
 * Party management, from inside a match.
 *
 * WHY THIS EXISTS AT ALL. A party and a squad are different things: the squad
 * is who you are fighting alongside right now, and it is fixed for the match;
 * the party is who you will still be with next match. Autofill means most
 * squads contain somebody you have never played with -- and the moment you
 * discover they are good is halfway through a match, which is precisely when
 * there was no way to say "let's keep playing" (owner, 2026-08-09).
 *
 * So this is the party, edited mid-match, and NOTHING here changes the squad.
 * Inviting a squadmate does not move them; removing someone from the party
 * leaves them on your team until the match ends. That separation is the whole
 * design and it is enforced server-side (br_core/server/party.lua) -- this
 * screen only asks.
 *
 * FOUR STATES, and the card is a different object in each:
 *
  *   no party        the recruit list, since inviting anybody creates one
 *   member          your party, who is in it, and the way out
 *   leader          the same, plus invite and remove
 *   invited         the incoming card, which outranks everything else here
 *
 * SQUADS ONLY. In solo there is no squad to recruit from and no party that
 * would survive the match, so the card does not render.
 */
/** A party cannot exceed a squad, because that would change what a squad is. */
const MAX_PARTY = 4

export default function PartyCard() {
  // TWO GROUPS, TWO CHANNELS. `squad` is who I am fighting with right now;
  // `party` is who I keep. Mid-match they differ, which is the entire reason
  // the party gets its own envelope -- see BR.Nui.PARTY.
  const squad = useUi(selSquad)
  const party = useUi((s) => s.party)
  const invite = useUi((s) => s.invite)
  const clearInvite = useUi((s) => s.clearInvite)

  const inParty = party.members.length > 1
  const you = party.you ?? squad.you
  // Not in a party yet? Then I lead the party of one that inviting somebody
  // will create -- the server treats an invite from no party as creating one,
  // so refusing to show the control here would only hide a path that works.
  const iAmLeader = !inParty || (you != null && party.leader === you)
  const full = party.members.length >= MAX_PARTY

  // Everyone I am fighting with who is not already in my party. In a squad
  // formed by autofill this is the list that matters -- the people you have
  // just spent twenty minutes with.
  const partySrcs = new Set(party.members.map((m) => m.src))
  const pendingSrcs = new Set((party.pending ?? []).map((p) => p.src))
  const recruitable = squad.members.filter(
    (m) => m.src !== you && !partySrcs.has(m.src) && !pendingSrcs.has(m.src))

  const respond = async (accept: boolean) => {
    play(accept ? 'ui.ready' : 'ui.back')
    const wasJoinReq = invite?.kind === 'joinreq'
    const requester = invite?.from
    clearInvite()
    if (wasJoinReq) {
      await fetchNui(CB.SQUAD_JOINRESP, { requester, accept })
    } else {
      await fetchNui(CB.SQUAD_RESPOND, { accept })
    }
  }

  return (
    <div
      className="plate px-5 py-3 mb-4"
      style={{
        ['--edgec' as string]: 'rgba(255,255,255,0.16)',
        ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
        ['--cut-max' as string]: '0.6rem',
      }}
    >
      <div className="flex items-center gap-6 py-1">
        <div className="flex-1 min-w-0">
          <div
            className="font-display uppercase tracking-[0.08em] ts"
            style={{ ['--fs' as string]: '1.05rem' }}
          >
            {inParty ? 'Your party' : 'Party'}
          </div>
          <div className="body-text mt-0.5">
            {inParty
              ? 'Stays together after this match ends.'
              : 'Start one to keep playing with this squad after the match.'}
          </div>
        </div>

        {inParty && (
          <div className="shrink-0">
            <Btn variant="default" size="sm" cue="ui.back"
                 onPress={() => { play('ui.back'); void fetchNui(CB.SQUAD_LEAVE, {}) }}>
              Leave party
            </Btn>
          </div>
        )}
      </div>

      {/* THE INCOMING CARD OUTRANKS EVERYTHING, because it expires. It must
          never be something a player has to go looking for -- which is exactly
          what it was in a match, where the lobby's copy of this card is not on
          screen at all. */}
      {invite && (
        <div
          className="rise plate flex items-center gap-3 px-3 py-2 mt-2"
          style={{
            ['--edgec' as string]: 'var(--color-royale-accent)',
            ['--plate-fill' as string]: 'rgba(10,44,56,0.94)',
            ['--cut-max' as string]: '0.4rem',
          }}
        >
          <span className="flex-1 ts" style={{ ['--fs' as string]: '0.9rem' }}>
            <span className="font-semibold">{invite.name}</span>
            <span className="text-white/60">
              {invite.kind === 'joinreq' ? ' wants to join your party' : ' invited you to their party'}
            </span>
            <span className="text-white/40"> ({invite.size}/{invite.max})</span>
          </span>
          <Btn size="sm" variant="primary" onPress={() => respond(true)}>Accept</Btn>
          <Btn size="sm" variant="ghost" cue="ui.back" onPress={() => respond(false)}>
            Decline
          </Btn>
        </div>
      )}

      {inParty && (
        <div className="flex flex-wrap items-center gap-1.5 mt-2">
          {party.members.map((m) => (
            <span
              key={m.src}
              className="plate px-2.5 py-1 text-[0.72rem] font-semibold flex items-center gap-1.5"
              style={{
                ['--edgec' as string]: m.colour,
                ['--plate-fill' as string]: 'rgba(26,30,42,0.94)',
                ['--cut-max' as string]: '0.4rem',
              }}
            >
              {m.leader ? '★ ' : ''}{m.name}
              {/* A LABEL, NOT A GLYPH. This was a bare × at 0.72rem, which is
                  "super super small and has no label to tell me what it does"
                  (user, 2026-08-09) -- and it is a destructive action, which
                  is the last place to be terse. It says Remove.
                  REMOVING SOMEONE DOES NOT REMOVE THEM FROM THE FIGHT: they
                  stay on the squad until the match ends, because pulling a
                  player out of a team mid-match would strip three people's
                  health bars and blips over one person's decision. */}
              {inParty && iAmLeader && m.src !== you && (
                <button
                  type="button"
                  className="btn plate px-2 py-0.5 ml-1 text-[0.68rem] font-semibold
                             uppercase tracking-[0.08em]"
                  style={{
                    ['--edgec' as string]: 'var(--color-danger-edge)',
                    ['--plate-fill' as string]: 'rgba(52,20,24,0.9)',
                    ['--cut-max' as string]: '0.25rem',
                    color: '#ffd7d7',
                  }}
                  title={`${m.name} stays on your squad for this match`}
                  onPointerEnter={() => play('ui.hover')}
                  onClick={() => {
                    play('ui.back')
                    void fetchNui(CB.SQUAD_KICK, { target: m.src })
                  }}
                >
                  Remove
                </button>
              )}
            </span>
          ))}

          {(party.pending ?? []).map((p) => (
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
      )}

      {/* RECRUITING FROM THE SQUAD. Only the leader, only people not already
          in the party, and only up to the squad size -- a party is capped at
          the same four a squad is, because widening it would quietly change
          what a squad means. */}
      {iAmLeader && recruitable.length > 0 && (
        <div className="mt-2">
          <div className="micro-label mb-1.5">
            {full
              ? `Party is full (${MAX_PARTY})`
              : 'Invite from your squad — they stay with you after this match'}
          </div>
          <div className="flex flex-wrap gap-1.5">
            {recruitable.map((m) => (
              // "+ Name" said nothing about what the plus would do. The verb
              // is on the button now, at a size somebody can hit.
              <button
                key={m.src}
                type="button"
                disabled={full}
                className="plate btn px-3 py-1.5 text-[0.8rem] font-semibold"
                style={{
                  ['--edgec' as string]: full
                    ? 'rgba(255,255,255,0.12)' : 'var(--color-royale-accent)',
                  ['--plate-fill' as string]: full
                    ? 'rgba(26,30,42,0.94)' : 'rgba(10,44,56,0.94)',
                  ['--cut-max' as string]: '0.4rem',
                  opacity: full ? 0.4 : 1,
                }}
                onPointerEnter={() => { if (!full) play('ui.hover') }}
                onClick={() => {
                  play('ui.select')
                  void fetchNui(CB.SQUAD_INVITE, { target: m.src })
                }}
              >
                Invite {m.name}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
