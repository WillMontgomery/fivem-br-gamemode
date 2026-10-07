/**
 * THE PERSISTENT NOTICES' ROWS, AS PURE ARITHMETIC (#396, round 4).
 *
 * Owner, 2026-10-06: "Anything that a player is being impacted by, which
 * happened as a result of another player's actions at a terminal, should show a
 * persistent notification with a timer explaining what the impact is and when
 * it will be over."
 *
 * THE SERVER DECIDES EVERY ROW (br_core's server/terminalfx.lua): what is
 * happening to this player, in words picked for them, and when it ends on the
 * server's clock -- or, for a row that lasts the rest of the match, the words
 * that stand in for a clock. It sends this player's whole list when it
 * changes; br_core's client hands it over as the `impacts` envelope. This file
 * only shape-checks what arrives, so a row the page draws is always a line of
 * text with either a finite end or its tail -- never `undefined`, never NaN.
 *
 * NO IMPORTS, for test-countdown.mjs's reason: node loads this .ts as-is
 * (scripts/test-impacts.mjs).
 */

/** One row: what it is, and when it ends (server ms) or what stands in for that. */
export interface ImpactRow {
  key: string
  text: string
  endsAt?: number
  tail?: string
}

/** The most rows a list may carry, and the longest line. The server sends a
 *  handful at most; past these it is not the server. */
export const IMPACTS_MAX = 12
export const IMPACT_TEXT_MAX = 200

/**
 * The rows in an `impacts` payload, shape-checked: a list (Lua's empty table
 * may cross as `{}` rather than `[]`), each row a non-empty line of text and
 * either a finite `endsAt` or a `tail` -- a row with neither has nothing to show
 * on its right, and is still drawn, with nothing there.
 */
export function parseImpacts(d: unknown): ImpactRow[] {
  const raw = d !== null && typeof d === 'object' ? (d as { list?: unknown }).list : undefined
  if (!Array.isArray(raw)) return []
  const out: ImpactRow[] = []
  for (const r of raw) {
    if (out.length >= IMPACTS_MAX) break
    if (r === null || typeof r !== 'object') continue
    const row = r as Record<string, unknown>
    if (typeof row.text !== 'string' || row.text.trim() === '') continue
    const parsed: ImpactRow = {
      key: typeof row.key === 'string' ? row.key : '',
      text: row.text.slice(0, IMPACT_TEXT_MAX),
    }
    if (typeof row.endsAt === 'number' && Number.isFinite(row.endsAt)) {
      parsed.endsAt = Math.floor(row.endsAt)
    } else if (typeof row.tail === 'string' && row.tail.trim() !== '') {
      parsed.tail = row.tail.slice(0, IMPACT_TEXT_MAX)
    }
    out.push(parsed)
  }
  return out
}

/**
 * A React key for each row: its copy key, made unique by its place among rows
 * that share one (the server sends one row per key, but a page never trusts
 * that to keep React's keys apart).
 */
export function impactKeys(rows: ImpactRow[]): string[] {
  const seen = new Map<string, number>()
  return rows.map((r) => {
    const n = seen.get(r.key) ?? 0
    seen.set(r.key, n + 1)
    return n === 0 ? `i:${r.key}` : `i:${r.key}:${n}`
  })
}
