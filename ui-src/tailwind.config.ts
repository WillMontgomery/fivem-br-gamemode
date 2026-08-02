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
        royale: {
          bg:      '#14151f',
          panel:   '#1d1e2b',
          edge:    '#33354a',
          accent:  '#a855f7',
          accent2: '#4cc9f0',
        },
        hp:     '#4ade80',
        shield: '#38bdf8',
        storm:  '#9333ea',
        danger: '#ef4444',
      },
      fontFamily: {
        display: ['Rajdhani', 'Segoe UI', 'system-ui', 'sans-serif'],
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
            primary: {
              DEFAULT: '#a855f7',
              foreground: '#ffffff',
            },
            focus: '#a855f7',
          },
        },
      },
    }),
  ],
} satisfies Config
