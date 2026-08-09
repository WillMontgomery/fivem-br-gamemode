import type { Config } from 'tailwindcss'
import { heroui } from '@heroui/react'

// Tailwind 3, not 4, deliberately.
//
// FiveM's CEF reports Chrome 103. Tailwind 4's default palette is authored in
// oklch() and Chrome 103 cannot parse it -- an unparseable colour is dropped
// entirely, so components render with no colour at all and it looks like the
// stylesheet failed to load. Tailwind 3 emits rgb/hsl, which has worked for
// years.
//
// HeroUI 2 is a Tailwind PLUGIN rather than a prebuilt stylesheet: it generates
// its colours at build time as HSL. Verified against the published package --
// zero occurrences of oklch, oklab, lch or color-mix.
export default {
  content: [
    './index.html',
    './src/**/*.{js,ts,jsx,tsx}',

    // HeroUI's component classes live in @heroui/theme and must be SCANNED or
    // Tailwind purges every one of them -- the components then render with
    // correct markup and no styling at all, which looks like a broken build.
    //
    // Two globs on purpose. npm does not reliably hoist @heroui/theme to the
    // top level: in this tree it resolved under @heroui/form/node_modules,
    // so the documented path matched nothing and produced exactly that
    // symptom. The recursive glob catches it wherever npm decides to put it.
    './node_modules/@heroui/theme/dist/**/*.{js,mjs,ts,tsx}',
    './node_modules/**/@heroui/theme/dist/**/*.{js,mjs,ts,tsx}',
  ],

  darkMode: 'class',

  theme: {
    extend: {
      colors: {
        // ONE COLOUR, ONE MEANING, GAME-WIDE.
        //
        // The old palette had a single purple doing five jobs -- brand mark,
        // every button, the lobby backdrop, own-kill highlights -- and sitting
        // one shade from Epic loot, so a purple glow on the ground was about
        // to mean two opposite things.
        //
        // Now: cyan means YOU MAY ACT. Magenta means THE STORM. Gold means
        // victory and nothing else. The five rarity colours belong to loot and
        // are never borrowed for chrome.
        royale: {
          bg:      '#0b0c12',
          panel:   '#1d1e2b',
          edge:    '#33354a',
          accent:  '#22d3ee',   // brand cyan
          accent2: '#facc15',   // victory gold
        },
        hp:     '#4ade80',
        shield: '#38bdf8',
        storm:  '#c026d3',      // magenta: clears Epic #a855f7 at a glance
        danger: '#ef4444',
        // Canonical. Players arrive already knowing these -- do not redesign.
        rarity: {
          1: '#9ca3af',
          2: '#22c55e',
          3: '#3b82f6',
          4: '#a855f7',
          5: '#f59e0b',
        },
      },
      fontFamily: {
        // If the player reads it under pressure, or it is a shout, it is
        // Anton. Everything else is Barlow. Rajdhani was declared here for
        // months and never loaded -- the whole interface was rendering in
        // Segoe UI.
        display: ['Anton', 'Segoe UI', 'system-ui', 'sans-serif'],
        sans:    ['Barlow', 'Segoe UI', 'system-ui', 'sans-serif'],
      },
    },
  },

  plugins: [
    heroui({
      // The HUD is dark and the lobby sits over the game, so light mode would
      // be actively wrong here rather than merely unused.
      defaultTheme: 'dark',
      themes: {
        dark: {
          colors: {
            // Cyan, matching --color-royale-accent. Recolours every lobby
            // button in one line. Dark foreground because the brand is a
            // bright colour and white-on-cyan does not hold contrast.
            primary: {
              DEFAULT: '#22d3ee',
              foreground: '#04222a',
            },
            focus: '#22d3ee',
          },
        },
      },
    }),
  ],
} satisfies Config
