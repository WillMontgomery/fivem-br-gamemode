import { BUILT_IN, type PresetSpec } from './tokens'

/**
 * THE PRESET REGISTRY (#431): a preset is a NAME with two halves.
 *
 *   TS   its timings, here (registerPreset): per channel a duration, a start
 *        after the anchor's turn and a curve, plus the stagger.
 *   CSS  its hidden values, as `[data-bc-preset="<name>"] { --bc-pre-*: ... }`
 *        (motion.css for broadcast, page, quickHide and none;
 *        motion/<name>.css for the rest). A channel the rule does not name
 *        stays where it is.
 *
 * A screen picks its preset in ONE place: <PresenceScope preset="...">. Every
 * presence under it takes that name, which also lands on its root as
 * data-bc-preset, so the CSS and the timings always agree.
 */

const registry = new Map<string, PresetSpec>(BUILT_IN.map((p) => [p.name, p]))

/** The default, and the fallback for a name nobody registered. */
export const DEFAULT_PRESET = 'broadcast'

/** Add (or replace) a preset. Its CSS rule must exist under the same name. */
export function registerPreset(spec: PresetSpec): void {
  registry.set(spec.name, spec)
}

export function getPreset(name: string | undefined): PresetSpec {
  return registry.get(name ?? DEFAULT_PRESET) ?? registry.get(DEFAULT_PRESET)!
}

export function presetNames(): string[] {
  return [...registry.keys()]
}
