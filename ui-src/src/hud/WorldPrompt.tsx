import { useUi } from '../store'
import { RARITY } from '../bridge/types'

/**
 * The interaction prompt, anchored to a thing in the world.
 *
 * Lua sends the screen position (0..1 fractions from GET_SCREEN_COORD_FROM_
 * WORLD_COORD) along with what is being looked at; this draws the label, the
 * key and -- for containers -- a progress ring around it.
 *
 * WHY THE RING IS HERE AND NOT IN LUA: GTA has no arc-drawing native, so a
 * circular progress bar drawn in-engine means a sprite sheet or a stack of
 * rotated rectangles. SVG does it in one element with a dash offset, and it
 * lands on top of the game exactly where the crate is.
 *
 * Positioned with `left`/`top` percentages and translated back by half its own
 * size, so it stays centred on the crate at any resolution.
 */

const R = 26          // ring radius in SVG units
const C = 2 * Math.PI * R

export default function WorldPrompt() {
  const p = useUi((s) => s.prompt)
  if (!p || !p.show) return null

  const hex = p.rarity ? RARITY[p.rarity].hex : '#FFFFFF'
  const pct = Math.min(1, Math.max(0, p.pct ?? 0))

  return (
    <div
      className="fixed pointer-events-none"
      style={{
        left: `${(p.x ?? 0.5) * 100}%`,
        top: `${(p.y ?? 0.5) * 100}%`,
        transform: 'translate(-50%, -50%)',
      }}
    >
      <div className="flex flex-col items-center gap-1">
        {p.ring ? (
          <div className="relative" style={{ width: '4rem', height: '4rem' }}>
            <svg viewBox="0 0 64 64" width="100%" height="100%">
              <circle
                cx="32" cy="32" r={R}
                fill="rgba(0,0,0,0.45)"
                stroke="rgba(255,255,255,0.25)"
                strokeWidth="3"
              />
              {/* Starts at twelve o'clock and fills clockwise: -90deg plus a
                  dash offset, which is the whole trick. */}
              <circle
                cx="32" cy="32" r={R}
                fill="none"
                stroke={hex}
                strokeWidth="4"
                strokeLinecap="round"
                strokeDasharray={C}
                strokeDashoffset={C * (1 - pct)}
                transform="rotate(-90 32 32)"
              />
            </svg>
            {p.key && (
              <div
                className="absolute inset-0 flex items-center justify-center
                           text-sm font-black"
                style={{ color: 'white' }}
              >
                {p.key}
              </div>
            )}
          </div>
        ) : (
          p.key && (
            <div
              className="flex items-center justify-center rounded
                         text-[0.7rem] font-black"
              style={{
                width: '1.5rem', height: '1.5rem',
                backgroundColor: 'rgba(0,0,0,0.6)',
                border: '1px solid rgba(255,255,255,0.55)',
                color: 'white',
              }}
            >
              {p.key}
            </div>
          )
        )}

        <div
          className="px-2 py-0.5 rounded text-center"
          style={{ backgroundColor: 'rgba(0,0,0,0.55)' }}
        >
          <div
            className="text-[0.72rem] font-bold leading-none"
            style={{ color: hex }}
          >
            {p.label}
          </div>
          {p.hint && (
            <div className="text-[0.55rem] uppercase tracking-[0.14em] text-white/55 mt-0.5">
              {p.hint}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
