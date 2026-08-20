import { useUi } from '../store'

/**
 * WHY YOU ARE HEARING NOBODY, ON THE SCREEN, WHILE IT IS TRUE.
 *
 * THE FAILURE THIS COMPONENT EXISTS FOR IS NOT A RENDERING FAILURE. Squad
 * voice worked -- the server minted a radio channel, every member of one squad
 * got the same one, the client joined it and pma-voice's own check let them on
 * -- and it passed no audio, because pma-voice's radio has a push-to-talk of
 * its own (Left Alt by default, at the time) and squad mode turns proximity
 * off, so the ordinary voice key carried nothing. Two players pressed the key
 * the game had taught them, heard silence, and reported the feature as broken.
 * The other half of the same trap: squad mode with NO squad is total silence by
 * design, and looks identical.
 *
 * ONE OF THOSE TWO IS NO LONGER THIS COMPONENT'S JOB, AND THE OTHER STILL IS.
 *
 * The key half is fixed at the source: push-to-talk is the gamemode's own
 * binding now (`brptt`, default N, rebindable on the settings screen), and it
 * is named ONCE at the start of a match by a notice rather than drawn here for
 * the whole of one. Lua stopped sending a `headline` for the WORKING radio
 * state -- owner, from the playtest: "don't give me text at the bottom of the
 * screen saying to hold any key to talk" -- so this renders nothing for it,
 * with no change on this side at all. That is the point of the words being
 * Lua's rather than this file's.
 *
 * What is left is the half that is genuinely wrong: squad mode with no squad,
 * a radio with nobody else on it, and 'off'. Those still send a headline and
 * this still draws it.
 *
 * SILENCE WITH NO EXPLANATION IS INDISTINGUISHABLE FROM A BROKEN FEATURE. That
 * is the whole argument for putting this on the HUD rather than leaving it in
 * `/brvoice`, which is a console command a player has never heard of, or in
 * Settings, which is a screen you have to already suspect something to open.
 *
 * THE WORDS ARE LUA'S, NOT THIS FILE'S. `headline` arrives on the voice
 * envelope, composed by BR.Voice.statusFor next to the code that decides which
 * state we are in. A page that composed its own sentence from `status` would be
 * a second place for the wording to be wrong, and this project's entire voice
 * history is two representations of one fact drifting apart.
 *
 * IT IS ABSENT MOST OF THE TIME, WHICH IS WHAT MAKES IT WORTH READING. Nearby
 * -- the default, and the mode almost everyone is on -- sends no headline at
 * all, so this renders nothing. A status line that is permanently up is
 * furniture, and furniture is not read.
 *
 * ABOVE THE TALKING BAR, sharing its baseline. They are the same subject and
 * they are never both interesting at once: if you can hear people, you do not
 * need telling why you cannot.
 */
export default function VoiceNotice() {
  const headline = useUi((s) => s.voice.headline)
  const silent = useUi((s) => s.voice.silent)
  const chosen = useUi((s) => s.voice.chosen)

  // Nothing to say is the common case and it renders nothing at all -- not an
  // empty plate holding the bottom of the screen for a whole match.
  if (!headline) return null

  // SILENT AND NOT ASKED FOR is the only state that gets the alarm colour.
  // 'off' is silent too and the player chose it two seconds ago; painting that
  // red would teach them the colour means nothing.
  const alarm = silent === true && chosen !== true

  return (
    <div
      className="absolute left-1/2 -translate-x-1/2 flex items-center gap-2
                 max-w-[56%] pointer-events-none"
      // Clear of the talking bar, which sits on --safe-y. One line of gap so
      // the two read as related rather than as one wrapped string.
      style={{ bottom: 'calc(var(--safe-y) + 1.6rem)' }}
    >
      <span
        className="shrink-0 rounded-full"
        style={{
          width: '0.34rem',
          height: '0.34rem',
          background: alarm
            ? 'var(--color-danger)'
            : 'var(--color-royale-accent)',
        }}
      />
      {/* `.ts` with an explicit --fs, and no `tscale` beside it: this element
          declares its own size, and bare tscale multiplies the PARENT's (#159).
          The text shadow is not optional -- this is drawn over the bare world,
          and the desert at noon is the failing case. */}
      <span
        className="ts truncate min-w-0"
        style={{
          ['--fs' as string]: '0.95rem',
          lineHeight: 1.5,
          fontWeight: alarm ? 700 : 400,
          color: alarm ? 'var(--color-danger)' : '#ffffff',
          textShadow: 'var(--shadow-text)',
        }}
      >
        {headline}
      </span>
    </div>
  )
}
