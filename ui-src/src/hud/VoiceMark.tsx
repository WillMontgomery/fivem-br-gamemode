/**
 * THE STATE OF ONE VOICE LINK, AS A MARK RATHER THAN A SENTENCE.
 *
 * Owner, 2026-08-22: "'Squad voice: nobody else on your squad radio yet' - how
 * about instead of showing this text, we show something in the top squad panel
 * next to each player which shows if they are muted, not listening, or talking.
 * I'm picturing icons like discord's mute/deafen/etc".
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * THE MODEL, AND WHAT IT IS ALLOWED TO CLAIM
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * THIS MARK IS NOT A STATEMENT ABOUT SOMEBODY ELSE'S SETTINGS. That is the
 * whole design constraint and it is worth stating before the glyphs, because
 * the obvious reading of the request -- "show me whether Dave has muted
 * himself" -- is a fact this client is not told and must not be told.
 *
 * WHAT A CLIENT ACTUALLY KNOWS ABOUT VOICE, exhaustively:
 *
 *   WHO IS TALKING. `VoicePayload.talking`, a list of server ids, already on
 *   the wire and already driving the bottom-centre line. It means "frames from
 *   this player are arriving and being decoded HERE" -- see the note on the
 *   talking indicator in br_core/client/voice.lua. It is honest for free: under
 *   pma-voice arrival IS audibility, so a name on that list is somebody this
 *   machine can genuinely hear.
 *
 *   ITS OWN VERDICT. `VoicePayload.silent` / `.chosen`, also already on the
 *   wire, composed by BR.Voice.statusFor next to the code that decides it.
 *   `silent` means something narrow and absolute: NOTHING CAN REACH THIS PLAYER
 *   AND NOTHING THEY SAY CAN LEAVE.
 *
 *   AND, SINCE 2026-08-29, ONE BIT ABOUT EACH SQUADMATE. `SquadMember.voiceOff`
 *   -- true when BR.VoiceMode.OFF is in force for them, whether they chose it,
 *   are spectating or are in the lobby. It is published by that player's own
 *   client on change, kept on their roster entry and carried to their squad and
 *   nobody else on the beacon that already carries positions, bleed deadlines
 *   and levels. See BR.Net.VOICE_STATE in br_lib/shared/protocol.lua.
 *
 * AND THAT IS THE COMPLETE LIST -- WHICH IS ONE ENTRY LONGER THAN IT WAS, AND
 * THE PARAGRAPHS BELOW ARE WHY IT IS ONLY ONE.
 *
 * THIS FILE USED TO REFUSE THAT HOP OUTRIGHT. Owner, 2026-08-29, after
 * playtesting: "the squad panel works, but doesn't accurately show when others
 * in the squad have 'off' selected" -- and, on being told the fact was on no
 * wire at all: "Why can't we build another client -> server -> squad hop? It
 * should only be processed at the start of a squad in warmup and whenever
 * changes occur." So it was built. What follows is the part of the old refusal
 * that SURVIVES, because two of its three arguments were never about `off`:
 *
 *   IT WIDENS WHAT A CLIENT IS TOLD ABOUT PEOPLE IT CANNOT SEE, and this one
 *   was real and was paid rather than dodged. The bill is one boolean, to one
 *   squad, on a channel that already carries a teammate's exact position. It is
 *   the third squad-only exception on that beacon, beside the bleed deadline
 *   and the level, and it is argued where it is implemented.
 *
 *   IT WOULD BE WRONG HALF THE TIME ANYWAY -- AND THIS IS WHY THE MODE IS STILL
 *   NOT PUBLISHED. A squadmate on 'nearby' is not on your radio, but IS audible
 *   when they are standing next to you. So "not on the radio" is not "cannot be
 *   heard", and a mark that said so would be a confident lie in exactly the
 *   situation -- a squad regrouping -- where it would be read hardest. 'off' is
 *   the one mode this does not apply to: it is absolute, at every distance,
 *   in both directions, for everybody.
 *
 *   AND THE HONEST VERSION OF IT IS A POSITION ORACLE. The only way to make
 *   "can I hear this mate right now" true on 'nearby' is to compare positions,
 *   and a panel that lit up when a squadmate came within 25 m would be a
 *   proximity sensor for players the client cannot otherwise see. Nothing about
 *   `voiceOff` needs a position, which is precisely what makes it publishable
 *   when the mode is not.
 *
 * SO THE LINE MOVED BY ONE BIT AND IS NOW ENFORCED RATHER THAN DESCRIBED.
 * tools/check_squad_voice.lua permits `voiceOff` by name across the boundary
 * and fails the build on any other voice field, on the squad payload and on
 * roster.lua's PUBLIC_FIELDS alike -- so publishing the mode is a change
 * somebody has to make deliberately, in that file, rather than one line of
 * drift in this one.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * SO: THREE STATES, AND THE THIRD ONE IS NOTHING AT ALL
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *   TALKING      this player is transmitting and it is reaching this machine.
 *                Drawn on ANY row. The accent speaker, on the slow pulse the
 *                talking indicator has always used.
 *
 *   NO VOICE     this player is in a state where nothing can reach them and
 *                nothing they say can leave. On the VIEWER'S OWN row that is
 *                `silent` off the voice envelope: the 'off' preference,
 *                squad-mode-with-no-squad, and being a SPECTATOR, where
 *                BR.Voice.mode() answers 'off' for the length of the session.
 *                On a SQUADMATE'S row it is `voiceOff` off the beacon, which is
 *                the same claim narrowed to the one mode that can be published
 *                honestly.
 *
 *                THE TWO ARE ONE GLYPH AND TWO COLOURS. `chosen` is
 *                --color-text-dim and is reachable on any row; `fault` is
 *                --color-danger and is the viewer's alone, because "this is
 *                wrong and you can fix it" is only ever true of the person who
 *                can open the settings screen. A mate's off is reported, not
 *                alarmed about.
 *
 *   NOTHING      a mate who is un-muted and simply not speaking, all the time.
 *                That is not a state; it is the absence of one, and the honest
 *                rendering of an absence is an empty slot.
 *
 * THAT LAST ROW IS THE ONE THIS FILE IS MOST OPINIONATED ABOUT. A mark on every
 * row for the whole of every match is furniture, and this project has now
 * removed three separate pieces of voice furniture from the bottom of the
 * screen for exactly that reason. "Silent" and "cannot speak" are distinct here
 * in the strongest way available: one of them draws nothing.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * THE GLYPHS ARE DRAWN HERE, AND THEY ARE OURS
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Discord is the reference for the IDEA and for nothing else -- its glyphs are
 * trademarked, this project ships nothing unlicensed and pays for nothing, and
 * no icon set is installed. These are two inline SVG paths written in this
 * file: a speaker cone, and one of two things in the slot to its right. Waves
 * mean sound is flowing; a cross means nothing is. Same object, one differing
 * element, which is what makes the pair read as one vocabulary rather than as
 * two unrelated pictures.
 *
 * INLINE SVG, NOT A FONT AND NOT AN IMAGE. A glyph font is another file in
 * fxmanifest's files{} to be forgotten (check-ui.mjs R6 exists because that
 * happened), and a PNG cannot take `currentColor` -- which is what lets these
 * follow --color-danger and the accent through the colourblind remaps.
 *
 * NOTHING HERE NEEDS ANYTHING NEWER THAN CHROME 103. Inline SVG, `currentColor`
 * and an opacity transition are all pre-2015. No `oklch`, no `color-mix`, no
 * `:has()`, no container query -- the HUD bundle is the SAME build as every
 * other screen and is loaded by the same CEF, so ui-src/scripts/check-css.mjs
 * gates this file exactly as it gates the console's screens.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * IT CANNOT FLICKER, AND IT CANNOT MOVE THE NAME
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Talking changes several times a second: MumbleIsPlayerTalking goes false in
 * the gaps between words, so a mark that mounted and unmounted with it would
 * blink, and -- worse -- would shove the name sideways every time, because the
 * mark sits before it.
 *
 * THE SLOT IS ALWAYS THERE. One square, one em on a side, rendered for every
 * row whether or not it has anything in it. The name's left edge is therefore
 * fixed for the life of the panel. (The dot this replaces was rendered
 * conditionally and did move the name.)
 *
 * AND THE GLYPHS FADE RATHER THAN APPEAR. 200ms on opacity, which is longer
 * than the 100ms band Lua pushes on -- so a one-tick dropout mid-sentence dips
 * the mark instead of clearing it, and it is back to full before the eye has
 * finished reading the dip. Both glyphs are mounted at all times and only their
 * opacity moves, so there is no element to remount and no animation to restart.
 *
 * THE PULSE RUNS UNCONDITIONALLY for the same reason. `.mate-talk` is applied
 * whether or not this row is talking: toggling the class restarts the keyframe,
 * and a restart inside a 200ms fade is a visible scale jump -- the exact jitter
 * this section exists to prevent. It is transform and opacity only, which is
 * what check-ui.mjs R7 requires of anything on the 60fps path, and it is
 * invisible at opacity 0.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * SIZE
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * `.ts` with an explicit `--fs`, never bare `.tscale` -- this element declares
 * its own size and `.tscale` multiplies 1em, the PARENT's, which throws the
 * declared value away (#159). The square is `1em` on a side, so it is that
 * font size, so it carries the player's text-size preference the way every
 * other declared size in the HUD does.
 *
 * IT CANNOT GROW THE ROW IT SITS IN, and that is arithmetic rather than luck.
 * The squad row's name is 0.72rem on the inherited line-height of 1.5, so the
 * line box is 1.08rem; the mark at the same --fs is 0.72rem, and 0.828rem at
 * the largest text setting (1.15). Both are under the line box, so the flex
 * line -- and the plate, and the panel PlayerList measures -- keep their height
 * at every setting. Measured in the dev harness at 0.90 / 1.00 / 1.15.
 */

/** The speaker cone. Shared by both states -- it is the same object. */
const CONE = 'M3.2 6.2h2.3L9 3.1v9.8L5.5 9.8H3.2Z'

function Glyph({ sound }: { sound: boolean }) {
  return (
    <svg
      viewBox="0 0 16 16"
      fill="none"
      // Fills the slot, which is where the size actually comes from.
      style={{ display: 'block', width: '100%', height: '100%' }}
      aria-hidden
    >
      <path d={CONE} fill="currentColor" />
      {sound ? (
        <>
          {/* Two arcs leaving the cone. Both are chords shorter than their
              own diameter, so the arc is always drawable -- an arc whose
              endpoints are further apart than 2r is silently re-scaled by the
              renderer and comes out as a different shape. */}
          <path
            d="M11.1 5.6a3.4 3.4 0 0 1 0 4.8"
            stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"
          />
          <path
            d="M13 3.6a6.4 6.4 0 0 1 0 8.8"
            stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"
          />
        </>
      ) : (
        <>
          {/* A cross in the slot the waves would occupy, rather than a slash
              across the whole glyph. A diagonal over the cone needs a cut-out
              stroke in the plate's own fill to stay legible, and the plate's
              fill is set per row (it goes red when a mate is downed) -- so the
              cut would be the one part of this that had to know about the row
              it landed in. The cross needs nothing. */}
          <path
            d="M10.7 6.3 14.1 9.7"
            stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"
          />
          <path
            d="M14.1 6.3 10.7 9.7"
            stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"
          />
        </>
      )}
    </svg>
  )
}

export default function VoiceMark({ fs, talking, silent = null }: {
  /** The size this mark declares, e.g. '0.72rem'. Multiplied by the player's
   *  text-size preference through `.ts`. */
  fs: string
  /** This player is transmitting and it is reaching this machine. */
  talking: boolean
  /** 'chosen' is a silence that player asked for -- the 'off' preference, or
   *  spectating. On the viewer's own row it comes off the voice envelope; on a
   *  squadmate's it comes off `SquadMember.voiceOff`. 'fault' is a silence they
   *  did NOT ask for -- squad mode with no squad -- and is the VIEWER'S OWN ROW
   *  ONLY, because nothing publishes that state about anybody else and it names
   *  a fix only the viewer can apply. Null whenever voice is carrying. */
  silent?: 'chosen' | 'fault' | null
}) {
  return (
    <span
      className="ts relative shrink-0"
      style={{
        ['--fs' as string]: fs,
        display: 'block',
        width: '1em',
        height: '1em',
        // ═══ THE ONE DECLARATION THAT KEEPS A PANEL FROM MOVING ═══
        //
        // This mark is the FIRST item of a flex row, and a flex container with
        // no baseline-aligned items synthesises its baseline from the bottom
        // edge of that first item. So a mark that grew with the text-size
        // preference dragged its whole row's baseline down with it -- measured
        // at 1.15 in the squad panel: every downed and dead plate 0.6px taller
        // and the whole panel 1.65px, for a mark that is meant to change
        // nothing but itself.
        //
        // `center` takes this element OUT of baseline alignment entirely, so
        // the row's baseline comes from the NAME beside it -- which does not
        // scale -- and the geometry is identical at 0.90, 1.00 and 1.15.
        // SquadPanel's row is `items-baseline` for that reason; see it there.
        alignSelf: 'center',
      }}
      aria-hidden
    >
      <span
        className="absolute inset-0"
        style={{
          color: 'var(--color-royale-accent)',
          opacity: talking ? 1 : 0,
          transition: 'opacity 200ms linear',
        }}
      >
        {/* The pulse is on the inner element so the fade above it and the
            breath below it multiply instead of fighting over one property. */}
        <span className="mate-talk" style={{ display: 'block', height: '100%' }}>
          <Glyph sound />
        </span>
      </span>

      <span
        className="absolute inset-0"
        style={{
          // The same rule VoiceNotice draws its headline with: a silence the
          // player chose is not an alarm, and painting one red teaches them
          // that the colour means nothing. --color-text-dim and --color-danger
          // are both remapped by the colourblind modes, so this follows the
          // setting.
          color: silent === 'fault'
            ? 'var(--color-danger)'
            : 'var(--color-text-dim)',
          opacity: silent ? 1 : 0,
          transition: 'opacity 200ms linear',
        }}
      >
        {/* STATIC, DELIBERATELY. The pulse means "this is happening now";
            having no voice is a standing condition, and animating it would
            make a settings choice compete with a fight for attention. */}
        <Glyph sound={false} />
      </span>
    </span>
  )
}
