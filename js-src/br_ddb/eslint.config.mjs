import globals from 'globals'

// ONE RULE, AND THE INCIDENT THAT BOUGHT IT (#235).
//
// aafe22a moved the stats expression into src/stats.js, where `deltas` is a
// local called `d`. The call site in src/index.js kept the old name and passed
// `buildStatsUpdate(d)`. esbuild treats an unbound identifier as a global and
// says nothing, so the bundle built clean, verify.sh went green, and the first
// thing to notice was a live server throwing `ReferenceError: d is not defined`
// on every match end -- silently, with XP, Volts and balances not persisting.
//
// `no-undef` is the whole point of this file. scripts/test.mjs now runs the
// handlers through scripts/bridge.mjs and would catch this one dynamically;
// this catches the class STATICALLY, on every branch, including the ones no
// test ever executes.
//
// DO NOT bolt a recommended ruleset onto this. A gate that also prints style
// opinions nobody asked for is a gate that gets switched off, and then the next
// `d` ships too.

export default [
  {
    // THE BUNDLE. FXServer runs server scripts on an embedded Node, so the Node
    // globals are genuinely present here. The three below are what the FXServer
    // runtime adds on top, and they are the only ones src/ uses -- confirmed by
    // running no-undef with an empty global set, and by scripts/bridge.mjs,
    // which stubs exactly these three to load src/index.js under test.
    files: ['src/**/*.js'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: {
        ...globals.node,
        on: 'readonly',        // subscribe to a server event
        emit: 'readonly',      // raise one
        GetConvar: 'readonly', // read server.cfg / tunables
      },
    },
    rules: { 'no-undef': 'error' },
  },
  {
    // BUILD AND TEST TOOLING. Plain Node -- it never runs inside FXServer, so
    // it does not get on/emit/GetConvar. bridge.mjs assigns them onto
    // globalThis, which is a property write and needs no declaration; a bare
    // `emit(...)` in here would be the same mistake as #235 and should go red.
    files: ['scripts/**/*.mjs'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: globals.node,
    },
    rules: { 'no-undef': 'error' },
  },
]
