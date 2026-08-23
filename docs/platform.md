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

**Which weapons may be fired from a vehicle seat is game DATA, not a native.**
`SET_PLAYER_CAN_DO_DRIVE_BY` is a per-player on/off switch and it defaults to
on; turning it on cannot make a rifle usable from a car. The real rule lives in
`vehiclelayouts.meta`: every seat names a `CVehicleDriveByInfo`, and that entry
carries a `WeaponGroup` list. Standard car seats list
`DRIVEBY_DEFAULT_UNARMED`, `DRIVEBY_DEFAULT_ONE_HANDED` and `DRIVEBY_THROW` —
so pistols, the SMG family and thrown weapons work from a seat, and rifles,
shotguns, snipers and MGs are taken out of the ped's hands on the way in. Two
of this project's reports are the same fact seen from different ends: "the HUD
is showing 0 bullets while in a vehicle" (2026-08-06, fixed by not reporting
ammo for a weapon the engine has stowed) and #197, "a passenger cannot fire".
A stowed weapon has no ammo reading *and* no trigger. **And the restriction
cannot be lifted from a resource** — see the next entry, which is the tested
half of this one. `/brdriveby` measures which of the causes is actually in play,
from the seat, in one command.

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

**Which virtual-key code a shift press fills is undocumented.** `IsRawKeyDown`
takes a *Windows* virtual-key code and reads GTA's own 256-slot keyboard array
(`(*ioKeyboardKeys)[*ioKeyboardActive][key]` in FiveM's `InputNatives.cpp`); the
native's own docs give `IsRawKeyDown(32)` for space, so the indexing is settled.
What is **not** settled by any source — the declaration, that source file, the
docs, or any forum thread — is whether shift fills `0x10` (`VK_SHIFT`), the
side-specific `0xA0`/`0xA1`, or all three. FiveM's mapper parameter table *does*
distinguish `LSHIFT` from `RSHIFT`, which is a reason to doubt that only the
generic slot is filled. `keybinds.lua` bet on `0x10` for the vehicle boost and
wrote the bet down as three converging inferences, none of which is an
observation; since #203 the raw reader asks all three for that binding
(`VK_ALSO`), which is a strict superset and costs nothing if the bet was right.

**It was wrong, and this build fills the side-specific slot only.**
`/brboostwhy 6` on the owner's machine: `0x10` never read down across 686 frames,
`0xA0` read down on 590 of them, `0xA1` never. So `VK_ALSO` is not a hedge — it
is the only reason the vehicle boost fires at all, and deleting it as redundant
would restore #203's original symptom exactly (full meter, dead key, no error).
`DEFAULT_VK` still stores `0x10` deliberately: it is the code the settings screen
captures (a browser `keydown` gives `keyCode` 16 for either shift), the code
`VK_NAME` prints as `Shift`, and the key `VK_ALSO` is looked up by. Moving it to
`0xA0` would narrow the raw read to one side, break right shift, and print
`#160`.

**`RegisterKeyMapping` and a stock GTA control coexist on the same key; neither
swallows the other.** FiveM evaluates custom bindings from the same
`rage::ioValue` device state the stock controls use, and *deliberately bypasses*
the game's own conflict resolver for them — custom control ids carry
`0x80000000` and `HandleMappingConflicts` returns early (`GameInput.cpp`). Both
fire. This is why aircraft are excluded from the boost rather than relying on
the binding to win the key, and why "some engine control is eating our keypress"
is not an available explanation for a binding that does nothing.

**GTA V has no drift-mode input, and nothing vanilla uses LSHIFT in a car.**
#203's playtest attributed a dead boost to "GTA V's drift mode... bound on
SHIFT". Drift Tuning (Chop Shop, b3095) is a *vehicle modification* bought at
Hao's — a handling change with no key, no toggle and no mode; there is no
`INPUT_*DRIFT*` control in any control table, and the only drift natives are
tyre-level (`_SET_DRIFT_TYRES_ENABLED`), which a script calls rather than a
player pressing. The belief comes from third-party FiveM drift *resources* that
bind left shift themselves. Re-checked after the second playtest: the Cfx control
table runs 0..359 (359 is `INPUT_RESPAWN_FASTER`) and **no control name in it
contains DRIFT or SLIDE**.

**A control reading PRESSED means the key is down, not that the engine did
something.** `IsControlPressed` / `IsDisabledControlPressed` answer the *mapper*
— "is the input bound to this id currently down" — and no native anywhere
reports whether the engine consumed it. Eight controls default to LSHIFT, so
holding shift makes every one of them read PRESSED, in any context, on any
build. `/brboostwhy` proved exactly that in a car (21, 61, 340 and 352 all
PRESSED on 590 of 686 frames) and it refutes the older claim in this file that
they would be silent there — but it does *not* mean four things happened to the
car. What each does when consumed is unchanged: 21 is on-foot sprint, 352 is
aircraft-only, 61 pitches an airborne vehicle, 340 needs hydraulics fitted.
`br_lib/config/boost.lua` carries the full reading and the two ids the boost
suppresses because of it.

Stated honestly: the public control table's last substantive update was November
2020 (build ~2189), so an input added between then and 3095 would not appear in
it. That gap is why `/brboostwhy` no longer trusts its own hardcoded four and
sweeps all 360 ids on the frames the key is held, naming anything else that
answers.

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

**A squad is a GTA team, which is how the false corpse is prevented rather than
repaired** (#115, `36581b2`). The section above is the general problem; this is
the one case that was solved, and it was solved by giving up on correcting the
shooter after the fact.

> **This section used to open "The friendly-fire pair in `applyGameRules`
> currently contradicts itself, and it is not fixed", and closed with "Do not
> write, in this repo or on the site, that teammates cannot damage each other."**
> Both were true when written and neither is now. The instruction in particular
> is the kind a later reader obeys without checking, so it is quoted here rather
> than deleted — the current answer is that a squadmate's shot is refused by the
> shooter's own engine before anything is computed.

**What replicates is what a client authors about *itself*.** That is the whole
lesson of the eight rounds before it. `BR_ALLY` was measured three times not to
stop player bullets, and `SetEntityCanBeDamaged(matePed, false)` was disproven by
playtest on 2026-08-19 — *"their ped fell over, then popped back up … it failed
immediately after a second attempt and they bled out, but only on my screen"*. A
ped that falls over **took** the damage. Both failed for one reason: a player's
ped is owned by their own machine, control of it can never be taken, and script
writes to their clone are not honoured.

FiveM's sync tree carries `playerTeam` (six bits) and `isFriendlyFireAllowed` in
`CPlayerGameStateDataNode`, beside `isInvincible` and the damage proofs. Those are
things a client says about itself, so they replicate. So:

- each squad takes a **team** — `1 + ((index − 1) % 63)`, derived from the squad
  id, never 0;
- a player **with a live squadmate closes the friendly-fire gate**
  (`NetworkSetFriendlyFireOption(false)`), which is no longer a constant;
- a **solo takes the reserved team 0 and leaves the gate open**, so solo play —
  the default mode — behaves exactly as it did before any of this existed.

**The load-bearing step is inferred and the file says so.** No source states in
words that GTA's damage path refuses a hit when shooter and victim share a team
*and* the gate is closed. Everything in the record supports it — `SET_PLAYER_TEAM`
is documented for "deathmatch and last team standing", the forum recipe names
`NetworkSetFriendlyFireOption(false)` as its prerequisite, and
`CPED_CONFIG_FLAG_IgnoreNetSessionFriendlyFireCheckForAllowDamage` exists to
*skip* that check inside the can-be-damaged path, which is proof the check is in
that path. Only a playtest closes it, and the owner cannot run the one that
matters: three clients against `maxSquadSize` 4 is one squad, so cross-squad
damage cannot be produced in game at all. Set `maxSquadSize = 2` and it can.

**So the blast radius is bounded rather than trusted.** Every unrecognised squad
id fails **open** — no team, gate open — because a pair of enemies who cannot hurt
each other is a worse bug than the one being fixed: it is invisible until somebody
loses a fight they should have won. A squad of one keeps its own team and an open
gate, read off the roster mirror rather than `squadmates.lua`'s `mates`, which the
server stops pushing to a squad of one — silence there is indistinguishable from a
dropped packet and must not close a gate on a guess.
`BR.Config.Match.engineTeams = false` reverts the lot in one line, byte-for-byte
to the pre-#115 behaviour. If squad matches suddenly have no combat at all, that
is the switch.

**The server half is unchanged and is still the authority.** Same-squad damage
that reaches the server anyway resolves to the `SAME_SQUAD` refusal in
`combat_solve.lua`, is cancelled, and is deliberately counted toward nothing (see
[security.md](security.md)). What the engine gate buys is that the shooter's
machine never computes the hit in the first place, so there is no local corpse to
correct — which is the only thing that was ever wrong with the server-side answer.

**Which weapons a vehicle seat accepts is game DATA, and no native reaches it.**
A passenger could not fire a rifle (#197, owner 2026-08-21) and the search went
straight to `SET_PLAYER_CAN_DO_DRIVE_BY` — which defaults to **on**, was already
being called, and was never the lever. The rule lives in `vehiclelayouts.meta`:
a seat names a `CVehicleDriveByInfo`, that names `CVehicleDriveByAnimInfo`
entries, and each of *those* names one `CDrivebyWeaponGroup`. The seat accepts
the union of those groups. A stock car seat gets unarmed, one-handed and thrown,
so a long gun is stowed on the way in and the ammo reads 0 — which is why
`probe.lua` had already recorded "the clip reading dropping to 0 in a seat is
EXPECTED" two weeks before anyone connected the two halves.

> **A mounted data file may NOT redefine a `CDrivebyWeaponGroup` the base game
> already has. Tested in game, 2026-08-22, and false.** We shipped exactly that
> — `DRIVEBY_DEFAULT_ONE_HANDED` and `DRIVEBY_DEFAULT_REAR_ONE_HANDED` restated
> by name under `data_file 'VEHICLE_LAYOUTS_FILE'`, listing every firearm the
> gamemode issues. The file was correct and `/brdriveby` read it back off the
> client, and the engine kept its own list regardless: *"carbine rifle in the
> passenger seat does nothing but pistols work"* (owner). Cfx hands the file
> straight to the game's own mounter — it only sorts `VEHICLE_LAYOUTS_FILE` and
> `HANDLING_FILE` ahead of the rest so layouts parse before `vehicles.meta` —
> and what the mounter does with a duplicate name is the game's business.
> **Upstream agrees, and it was found only afterwards:**
> [citizenfx/fivem#3929](https://github.com/citizenfx/fivem/issues/3929) — *"you
> can't override existing values in any of these"* — is the identical case,
> closed without a fix. It did not turn up in the research done before the file
> shipped because the searches were about `vehiclelayouts.meta` and drive-by, and
> the issue that answers it is filed under custom SMGs. **The lesson is the
> search terms, not the conclusion:** when a data file does not take effect, look
> for somebody overriding the same *kind of entry*, not the same file. **Do not
> re-derive this**; the write-up is in [vehicle-data.md](vehicle-data.md).
>
> **Adding a name the base game does not have is a different question and was
> not tested.** Every add-on vehicle in the wild depends on new layouts being
> accepted, so the two cases are not the same case.

Nothing widens the rule, so the remaining work was to stop it being invisible: a
passenger is told once per session which slot will actually fire
(`br_core/client/driveby.lua`), on the strength of a `driveby` boolean the
weapon table is required to carry.

---

