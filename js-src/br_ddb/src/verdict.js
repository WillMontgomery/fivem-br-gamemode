/**
 * Reading a verdict off an incident row.
 *
 * SEPARATE FROM index.js SO IT CAN BE TESTED, the same split as ban.js and
 * incident.js. The network call is untestable without a table; the rule that
 * decides whether 250 Volts are paid to a stranger is the part that has to be
 * right, and it is decided against a contract written in another repository.
 *
 * THE CONTRACT IS RINGMASTER'S `IncidentVerdict` (src/lib/incidents.ts). Copied
 * here in the same spirit ban.js copies the ban rule -- the alternative to
 * duplicating a dozen lines is publishing a shared package to a game server
 * that cannot install dependencies. The console's own file is the authority and
 * says so; this is the reader.
 *
 *   verdict.action     'ban' | 'kick' | 'none'   -- always present when `verdict` is
 *   verdict.expiresAt  number | null             -- PRESENT IF AND ONLY IF action
 *                                                   is 'ban'. null means permanent.
 *
 * READ `action` FIRST, ALWAYS. `expiresAt` does not exist on a kick or a
 * no-action verdict, and a reader that reaches for it without narrowing gets
 * `undefined` where a permanent ban would have given `null` -- two falsy values
 * meaning entirely different things.
 *
 * ABSENT OR NULL IS A REAL STATE AND IT IS NOT 'none'. Two kinds of resolved
 * incident carry no verdict at all: one resolved before the field existed, and
 * one the system auto-resolved, where no human decided anything. Neither may be
 * read as "no action was taken" -- that is a claim about a decision nobody made.
 * So `payable` is false for BOTH `none` and absent, and `settled` is true for
 * both as well: there is nothing to pay and nothing more to wait for. The two
 * are reported separately anyway, because "we paid nobody because an admin said
 * so" and "we paid nobody because the row predates the field" are different
 * facts about the same 250 Volts, and only one of them is worth a log line.
 *
 * DERIVE, DO NOT STORE, "was an action taken". It is `action !== 'none'`, and it
 * is computed here, once, rather than stored beside the enum where the two
 * would eventually disagree -- always in the direction of paying for a ban that
 * did not happen.
 */

/** The states an incident row may be in. Anything else is treated as pending. */
const RESOLVED = 'resolved'

/**
 * The word for the player-facing sentence, from `action` and nothing else.
 *
 * PAST TENSE, LOWER CASE, because it lands mid-sentence: "...who has now been
 * banned." The console's own VERDICT_LABEL is title case because it is a column
 * heading; this is prose.
 *
 * The admin's written resolution is NOT part of that sentence and never will
 * be. It is free text an admin wrote for other admins, and forwarding it to the
 * person who filed the report publishes it to a stranger.
 */
const WORD = {
  ban: 'banned',
  kick: 'kicked',
}

export function verdictWord(action) {
  return WORD[action] ?? null
}

/**
 * What the game is allowed to know about one incident.
 *
 * A PROJECTION, NOT A ROW. The caller asked "has this been decided, and did
 * anything happen" and that is all it gets back: four fields, none of which
 * names a person. The evidence, the chat log, the reporter, the subject and the
 * admin's resolution all stay on the row and never cross into the game server,
 * which is what keeps the new read narrower than the grant that allows it.
 *
 * @param {object|null|undefined} row  the unmarshalled item, or null if absent
 * @returns {{found: boolean, state: string|null, action: string|null,
 *            expiresAt: number|null, resolvedAt: number|null,
 *            settled: boolean, payable: boolean, word: string|null}}
 */
export function projectVerdict(row) {
  if (!row || typeof row !== 'object') {
    // NOT SETTLED. A row that is not there is not a decision -- it is a write
    // that has not landed, an id we got wrong, or a case somebody deleted out
    // of band. Reporting it as settled would drop the claim on the floor, so
    // the caller keeps waiting and the sweep's own age cap is what eventually
    // ends it.
    return {
      found: false,
      state: null,
      action: null,
      expiresAt: null,
      resolvedAt: null,
      settled: false,
      payable: false,
      word: null,
    }
  }

  const state = typeof row.state === 'string' ? row.state : null
  const resolved = state === RESOLVED

  const v = row.verdict
  const action =
    v && typeof v === 'object' && (v.action === 'ban' || v.action === 'kick' || v.action === 'none')
      ? v.action
      : null

  /**
   * ONLY ON A BAN, and `null` on a permanent one. Kept because it is free and
   * because a future reader will want it; deliberately not used to decide
   * anything here -- a temporary ban and a permanent one are the same 250 Volts.
   */
  const expiresAt =
    action === 'ban' && typeof v.expiresAt === 'number' ? v.expiresAt : null

  return {
    found: true,
    state,
    action,
    expiresAt,
    resolvedAt: typeof row.resolvedAt === 'number' ? row.resolvedAt : null,
    // A RESOLVED INCIDENT IS FINISHED WHETHER OR NOT IT CARRIES A VERDICT. The
    // console writes state and verdict in one conditional update that refuses to
    // run twice, so there is no window in which a resolved row is still waiting
    // for its verdict to arrive. An absent one is absent for good.
    settled: resolved,
    // The one derived question. Absent is NOT 'none' and is NOT payable: this
    // never converts "do not know" into an answer.
    payable: resolved && action !== null && action !== 'none',
    word: resolved ? verdictWord(action) : null,
  }
}
