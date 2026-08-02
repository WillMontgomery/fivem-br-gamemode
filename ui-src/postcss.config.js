// Tailwind 3 runs through PostCSS rather than a Vite plugin.
//
// autoprefixer matters more than usual here: the target is Chrome 103, so a few
// properties still want prefixes that modern defaults would omit.
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
