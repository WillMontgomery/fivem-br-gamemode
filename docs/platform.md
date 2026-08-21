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

**`IsRawKeyDown` is a level; `IsRawKeyPressed` is a single-frame edge.** Only
the first can answer the question a *hold* asks — "is this key down on this
frame". A build that predates `IsRawKeyDown` and falls back to `IsRawKeyPressed`
can see a press and can **never** see a hold, so it accumulates exactly one
frame per press and a hold threshold becomes unreachable. The capability check
must therefore be per-*question*, not all-or-nothing: `pcall`-ing the native
only asks whether the call throws, not what the answer means. Three rounds of
#129 rested on that distinction being assumed rather than measured;
`/brprobe rawkey [vk] [seconds]` now measures it by counting how many frames of
a real hold each native answers true for — a level answers on nearly every
frame, an edge on about one.

**A native declared BOOL may hand Lua a number.** `IsRawKeyDown` may answer
`true/false`, `1/false`, `1/0` or `1/nil` depending on the build, and **`0` is
truthy in Lua** — so the obvious normalisation `v and true or false` reads a
released key as held forever. `natives.lua` compares `hit == 1 or hit == true`
and `spawn.lua` compares `== true or == 1` for the same reason; both were
written after the value arrived as a number in play. Stubbing one shape in a
test proves only that shape (see [testing.md](testing.md), rule 4).

**`DISABLE_FRONTEND_THIS_FRAME` (`0x6D3465A73092F0E6`) is the only way to take
GTA's pause menu away.** Disabling controls 199/200 does not do it; this native
stops the frontend being *toggled*, from keyboard and from a controller's Start
alike. Two guards are needed or a pause menu you cannot open is a soft lock: the
suppression must follow the binding (rebind our menu off Escape and GTA's comes
straight back), and it needs the raw layer, so a client without one keeps the
engine's menu and reaches ours on a separate engine-side default.

**`SET_PLAYER_PARACHUTE_TINT_INDEX` picks a preset design, not a tint.** There
is no arbitrary RGB: canopy textures ship with the model and the index chooses
one. Several presets are plain single colours, which is what makes the name
plausible enough to mislead — but 2, 3, 4 and 7 are multi-colour striped
liveries no tint value could produce. Only **0–7** are reachable: 8–13 are the
flight-school designs and the engine clamps to the standard canopy's range on
`p_parachute1_mp_s`, so every index above 7 renders as Hornet. Observed in game
2026-08-15 (#78), not assumed.

**Do not write any Mumble distance native. pma-voice owns the engine now.** This
paragraph used to end "not adopted yet, recorded as the next step" — it *has*
been adopted, and `br_core/client/voice.lua` is what is left.

`MumbleSetAudioInputDistance` and `MumbleSetAudioOutputDistance` switch
`MumbleAudioOutput` onto a listener-to-speaker position comparison, and a speaker
whose position the engine does not have is **silenced outright** rather than
treated as near. That is what shipped a `nearby` mode which was silent nose to
nose while the talking indicator kept naming people. pma-voice's README asks
other resources not to touch those two, `MumbleSetTalkerProximity`,
`NetworkSetTalkerProximity` or `NetworkSetVoiceActive` — and every one of them is
a native some earlier round of that file reached for.

**The whole file now calls exactly one Mumble native, `MumbleIsPlayerTalking`,
and it is a read.** Every setter is gone. Our rules — three modes, squads, the
bus — are expressed through pma-voice's own extension points
(`addProximityCheck`, `addChannelCheck`, `overrideProximityRange`) rather than by
driving the mixer. `tools/test_client.lua` asserts the *negative* directly, that
none of those five natives is ever called, because it is the single easiest thing
for a later round to undo in good faith while fixing something else.

Why that shape wins, stated once so it is not re-litigated: **proximity is
enforced by the speaker.** Every player has their own Mumble channel and pma-voice
rebuilds each player's voice target four times a second from the channels of the
players near *them*. You hear somebody because they decided you were close
enough to send to — so out-of-range audio never leaves their machine, there is no
receive-side gate to get wrong, and a mistake costs one player's microphone
rather than one player's ears. The radio is the other half:
`MumbleAddVoiceTargetPlayerByServerId` resolves against the Mumble **user** list
rather than the channel list, so it reaches a squadmate the game has not streamed
in — which is what squad voice always needed.

Note also pma-voice's **3× range multiplier** under `voice_useNativeAudio`, so
that mismatch is diagnosed from `server.cfg.example` rather than from a
playtest.

**`CancelEvent()` on `weaponDamageEvent` suppresses replication and sends no
negative acknowledgement.** The shooter's engine has already decided the target
is dead and is waiting for a reply that never comes, so the victim reads as a
corpse on that one machine while being alive everywhere else. This is the **false
corpse (#115), and it is open.** Cfx.re's own people describe it as intended game
behaviour, note that it only happens on the client the damage originated from,
and the fix they name — synthesising a damage reply to the originating client —
is unimplemented upstream (citizenfx#2343, open since January 2024).
`NetworkSetEntityOwner` is still unmerged, so there is no server-side ownership
route either. **Answering it with a health write is a different message to a
system that is not listening for one**, which is what six successive rounds of
fixes were doing; the seventh commit is an instrument (`/brcorpse`) rather than a
seventh correction, because the previous one could not tell "never sent" from
"arrived and declined", and misread a write that lands and is reverted 100 ms
later as success.

**The friendly-fire pair in `applyGameRules` currently contradicts itself, and it
is not fixed.** `br_core/client/natives.lua` calls, on the same ped, every frame:

```lua
NetworkSetFriendlyFireOption(true)      -- friendly fire ON
SetPedRelationshipGroupHash(ped, BR.Native.ALLY_GROUP)
SetCanAttackFriendly(ped, false, false) -- same-group damage refused
```

The scheme is real and the reasoning around it is right: squadmates share
`BR_ALLY` (assigned to their local peds by `squadmates.lua` as they stream in),
everyone else stays in the engine's default `PLAYER` group, which `BR_ALLY`
hates, so enemies take damage as before. **But the lever it leans on is the
engine's no-PvP default — "everyone in `PLAYER` + `canAttackFriendly` false" —
and that default has the friendly-fire option *off*.** Setting it `true` on the
line above is the opposite of what the carve-out below it needs. The code's own
comment states the premise; the call breaks it.

**Nothing about a squad's health depends on this**, because the server refuses
the shot regardless: same-squad damage resolves to the `SAME_SQUAD` refusal in
`combat_solve.lua`, is cancelled, and is deliberately not counted toward anything
(see [security.md](security.md)). What the contradiction buys is the shooter's
engine computing and applying the hit locally first — which is the false corpse
above, pointed at a teammate. **Do not write, in this repo or on the site, that
teammates cannot damage each other.** The honest statement is that the server
never lets squad damage land, and that the client-side half of the arrangement is
currently misconfigured.

---

