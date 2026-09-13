/**
 * Which DynamoDB tables this box is allowed to name.
 *
 * ═══ WHY THIS IS A FILE AND NOT TWO `GetConvar` LINES ═══
 *
 * It used to be two lines in index.js. A dev box got its own tables by somebody
 * remembering to set `br_ddb_game_prefix` in its server.cfg, and a dev box that
 * nobody remembered wrote match results, XP and moderation cases straight into
 * the tables the live server reads. That is not a mistake anyone makes twice,
 * but it is one everybody makes once, and it is silent: the writes succeed.
 *
 * So the prefix now FOLLOWS THE DEV FLAG the rest of the project already has.
 * There is nothing extra to set and nothing extra to remember. A box is either
 * a dev box, in which case every table it names starts with `dev-`, or it is
 * not, in which case absolutely nothing here changes.
 *
 * ═══ FORCED, NOT DEFAULTED ═══
 *
 * On a dev box the two prefix convars are IGNORED, not merely overridden. A
 * default that an explicit convar can beat is the same footgun wearing a
 * different hat: the box that hurts you is precisely the one whose config
 * somebody edited without thinking about this. `dev-` is not a suggestion.
 *
 * The cost is real and worth naming: there is no way to point a dev box at a
 * third set of tables. The answer on a dev box is exactly `dev-ringmaster-` and
 * `dev-br-`, always, so the tables that have to exist in AWS are a fixed list
 * of six rather than whatever a config file happened to say. If a second set is
 * ever genuinely needed, that is a deliberate change here, not an accident in a
 * server.cfg.
 *
 * An ignored convar is not swallowed. `banner()` says which one was ignored and
 * what it said, because a setting that does nothing and says nothing is how an
 * operator ends up debugging the wrong box for an hour.
 *
 * ═══ BOTH FAMILIES, INCLUDING THE CONSOLE'S ═══
 *
 * `br-*` is obvious: it is the game's own data and the game writes all of it.
 *
 * `ringmaster-*` is the one worth arguing about, because the game box only
 * WRITES one table in that family (`ringmaster-incidents`, append-only) and
 * READS the other three. The write is reason enough on its own: a tester
 * filing a bogus report on the dev box should not put a case in front of a
 * moderator. But the reads move too, and deliberately, because the property
 * that is actually worth having is not "the dev box writes elsewhere" -- it is
 * `a dev box never names a production table at all`. That one can be enforced
 * in IAM, by giving the dev box an instance role scoped to `dev-*` and nothing
 * else, which is a guarantee no amount of care in this file can match.
 *
 * WHAT THAT COSTS, STATED PLAINLY: a dev box reads `dev-ringmaster-grants`, so
 * it does not know about admins granted on the live console, and it reads
 * `dev-ringmaster-bans`, so it does not know who is banned there. Both tables
 * start empty and stay empty until somebody puts a row in them.
 *
 * ═══ THE FLAG IS READ THE SAME WAY br_lib DOES IT ═══
 *
 * `br_lib/shared/devgate.lua` resolves dev mode as `sv_devMode` OR
 * `br_devMode`. br_ddb is a separate resource and cannot call into that Lua, so
 * the two convar names and the OR between them are copied here. BOTH names,
 * not one: a box where only `sv_devMode` is set is a dev box to every other
 * resource in the project, and the two halves disagreeing about which box this
 * is would be worse than either answer.
 */

/** What a dev box's table names begin with. Not configurable, on purpose. */
export const DEV_PREFIX = 'dev-'

/** The console's family: bans, grants, maintenance, incidents. */
export const TABLE_PREFIX_DEFAULT = 'ringmaster-'

/** The game's own family: players, matches. */
export const GAME_PREFIX_DEFAULT = 'br-'

/** The two convar names that mean "this is a dev box", in devgate.lua's order. */
export const DEV_CONVARS = ['sv_devMode', 'br_devMode']

/**
 * Which of the dev convars are on, in order. Empty means production.
 *
 * The LIST rather than a boolean, because the startup banner names them. A box
 * with only one of the two set is a state the operator should see, since
 * `br_devMode` is the replicated one and `sv_devMode` is not.
 *
 * @param {(key: string, fallback: string) => string} getConvar
 * @returns {string[]}
 */
export function devConvarsOn(getConvar) {
  return DEV_CONVARS.filter((name) => getConvar(name, 'false') === 'true')
}

/**
 * Resolve both table prefixes for this box.
 *
 * Takes `GetConvar` rather than calling the global, so the decision can be
 * tested without a FiveM runtime and without reloading a module.
 *
 * @param {(key: string, fallback: string) => string} getConvar
 * @returns {{
 *   dev: boolean,
 *   on: string[],
 *   table: string,
 *   game: string,
 *   ignored: Array<{ convar: string, value: string }>,
 * }}
 */
export function resolvePrefixes(getConvar) {
  const table = getConvar('br_ddb_table_prefix', TABLE_PREFIX_DEFAULT)
  const game = getConvar('br_ddb_game_prefix', GAME_PREFIX_DEFAULT)
  const on = devConvarsOn(getConvar)

  // THE PRODUCTION PATH, AND IT IS THE OLD ONE EXACTLY. Whatever the convars
  // say is what this box uses, defaults included. Nothing below this line runs
  // on a box that has not asked for dev mode.
  if (on.length === 0) {
    return { dev: false, on, table, game, ignored: [] }
  }

  const ignored = []
  if (table !== TABLE_PREFIX_DEFAULT) {
    ignored.push({ convar: 'br_ddb_table_prefix', value: table })
  }
  if (game !== GAME_PREFIX_DEFAULT) {
    ignored.push({ convar: 'br_ddb_game_prefix', value: game })
  }

  // NOT `DEV_PREFIX + table`. Prepending to the configured value would let an
  // explicit convar decide half the name, which is most of the way back to the
  // problem this exists to close. The shipped defaults are the only thing a
  // dev box builds on.
  return {
    dev: true,
    on,
    table: DEV_PREFIX + TABLE_PREFIX_DEFAULT,
    game: DEV_PREFIX + GAME_PREFIX_DEFAULT,
    ignored,
  }
}

/**
 * What to print at startup, one array entry per line.
 *
 * EMPTY ON A PRODUCTION BOX. The existing ready line already names both
 * prefixes, so a live server's console is byte-for-byte what it was. This block
 * is the extra that a dev box earns, and it is a diagnostic rather than UI: an
 * operator looking at a console should be able to answer "which tables is this
 * box about to touch" without reading any code.
 *
 * @param {ReturnType<typeof resolvePrefixes>} resolved
 * @returns {string[]}
 */
export function banner(resolved) {
  if (!resolved.dev) return []

  const lines = [
    `[br_ddb] DEV MODE (${resolved.on.map((n) => `${n}=true`).join(', ')}).`
      + ` Table prefixes forced to "${DEV_PREFIX}".`,
    `[br_ddb]   ${resolved.game}players, ${resolved.game}matches`
      + ' read/write (profile, inventory, stats, history, match rows)',
    `[br_ddb]   ${resolved.table}bans, ${resolved.table}grants,`
      + ` ${resolved.table}maintenance read-only,`
      + ` ${resolved.table}incidents append + verdict-read`,
    `[br_ddb]   This box will NOT touch ${TABLE_PREFIX_DEFAULT}* or`
      + ` ${GAME_PREFIX_DEFAULT}*. Those are production.`,
  ]

  for (const { convar, value } of resolved.ignored) {
    lines.push(
      `[br_ddb]   IGNORING ${convar} "${value}": dev mode is not overridable.`,
    )
  }

  return lines
}
