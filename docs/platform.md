# Platform constraints

FiveM and CEF behaviours discovered the hard way, and what each one cost.

[← Back to the main README](../README.md)

---

These are load-bearing and cost real time to find. Recorded here so the next
person doesn't repeat them.

**FiveM's CEF is Chrome 103.** It cannot parse `oklch()`, `oklab()`,
`color-mix()`, `:has()`, or CSS nesting. Tailwind 4 and HeroUI 3 emit those
throughout their colour systems, which is why this project pins **HeroUI 2 +
Tailwind 3**. An unparseable colour is not a fallback — the declaration is
dropped and the element renders invisible. `ui-src/scripts/check-css.mjs` fails
the build if any reach the bundle.

**`color-scheme: dark` paints the canvas opaque.** Separately from any
background-color. A component library's dark theme will black out the entire
game while `html`, `body` and `#root` all correctly report transparent. The fix
is `html { color-scheme: normal !important }` — the same line
[ox_lib](https://github.com/overextended/ox_lib) opens its stylesheet with.

**Entity culling is 424 units** and the natives to widen it are deprecated with
known unfixable issues. Players beyond that are not rendered and cannot be shot,
so weapon ranges and late-game circle sizes are designed around it.

**`GET_PLAYER_PED` takes a string.** Passing the numeric server id returns 0 for
every player, silently.

**Server-side entity access requires OneSync.** Without it every position read
returns nothing and nothing errors.

**A parachute is a weapon, and its AMMO is what "has a parachute" means.**
Opening the canopy does not consume it — the ped keeps `GADGET_PARACHUTE` with
its count intact, which the engine reads as a chute still available. That is
one bug (a reserve chute, and the vanilla deploy prompt returning on landing)
wearing three different faces across four sessions. The count is zeroed the
instant the canopy appears, removal at touchdown is retried across real frames
rather than assumed, and a standing 10 Hz sweep disarms any grounded live
player still holding one.

**Native names keep an underscore before digit-leading segments.**
`GetGroundZFor_3dCoord`, not `GetGroundZFor3dCoord` — the latter is `nil`, and
a nil native is not an error, it is a silent no-op. `luac -p` cannot see it and
unit tests stub it. Every native a new subsystem leans on gets a probe in
`brnativecheck` **before** the in-game test.

---

