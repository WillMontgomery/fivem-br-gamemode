/**
 * HOW MUCH OF A JERRY CAN'S GAUGE IS LIT (#217): a share of its height, 0..1.
 *
 * hud/FuelGauge.tsx draws the bar at this height and nothing else decides it;
 * scripts/test-fuel-gauge.mjs holds the rule. No runtime imports, so node's
 * type stripping loads this file as-is (the vitalsPlacement.ts shape).
 *
 * THE FILL ITSELF -- BUT NEVER LESS THAN A SLIVER WHILE THE CAN HOLDS ANYTHING.
 * The server keeps a can down to a millionth of its fill and sends it to a
 * thousandth, never 0 while there is any left (server/inventory.lua's
 * canFill). Drawn as it is, a thousandth of the HUD plate's 2.8rem gauge is a
 * twentieth of a pixel at 1080p, and anything under about a hundredth is less
 * than one: a can that looked empty, still taking the one place a player may
 * carry one and refusing the next can they find (#217's second review). So any
 * fill above 0 is drawn at least SLIVER tall -- 8% of the gauge, about 3.5px
 * of the HUD plate's -- and 0 is drawn empty. An empty can has left the bag by
 * then anyway, so 0 is never what a can on a plate shows.
 *
 * A VALUE THAT IS NOT A NUMBER READS AS EMPTY rather than as a height CEF
 * would drop, and one past 1 as full. The server sends 0..1 to three decimals,
 * so neither should ever come up.
 */
export const SLIVER = 0.08

export function gaugeShare(fill: number | null | undefined): number {
  if (typeof fill !== 'number' || !Number.isFinite(fill) || fill <= 0) return 0
  return Math.max(SLIVER, Math.min(1, fill))
}
