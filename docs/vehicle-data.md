# Vehicle data overrides

Which weapons a vehicle seat accepts, why we cannot change it, and how to fold
an add-on vehicle's own `vehiclelayouts.meta` in.

[← Back to the main README](../README.md)

---

## The finding, first

> **A `vehiclelayouts.meta` mounted by a FiveM resource CANNOT redefine a
> `CDrivebyWeaponGroup` that the base game already defines. The game keeps its
> own and ignores yours.**
>
> **Tested in game on 2026-08-22 and false.** We shipped exactly that file —
> `DRIVEBY_DEFAULT_ONE_HANDED` and `DRIVEBY_DEFAULT_REAR_ONE_HANDED` redefined
> by name, mounted as `data_file 'VEHICLE_LAYOUTS_FILE'`, both groups listing
> every firearm in `br_lib/config/weapons.lua`. Owner, from a passenger seat:
> *"Seems vehiclelayouts.meta didn't land — carbine rifle in the passenger seat
> does nothing but pistols work."* The file was correct, it reached the client
> (`/brdriveby` read it back), and the engine kept its own list anyway.
>
> **This cost a playtest round to establish. Do not re-derive it.** #197 was
> closed as *no plan to fix* on the strength of it; the override has been backed
> out.

**Upstream says the same thing, and it was found only after the playtest.**
[citizenfx/fivem#3929](https://github.com/citizenfx/fivem/issues/3929) — *"Custom
SMGs don't have default drive-by availability"*, closed without a fix — is the
identical case, reported by a CitizenFX contributor:

> "So I found out the culprit: drive-by weapons are defined in
> vehiclelayouts.meta … The issue is that I can't seem to override existing keys
> defining WeaponTypeNames … The path to customizing drive-by weapons is
> CVehicleLayoutInfo → SeatAnimInfo → DriveByInfo → DriveByAnimInfos →
> WeaponGroup → WeaponTypeNames but **you can't override existing values in any
> of these.**"

The same limitation has an open feature request against it
([#1245](https://github.com/citizenfx/fivem/issues/1245), *"vehicles.meta changes
only affect addon vehicles"*, open since 2022) and a
[Cfx forum request from 2017](https://forum.cfx.re/t/ability-to-overwrite-existing-meta-xml-entries-with-stream-files/4147).
None of this turned up in the research done *before* the file shipped, because
the searches were about `vehiclelayouts.meta` and drive-by; the issue that
answers it is filed under custom SMGs. **The lesson is the search terms, not the
conclusion** — when a data file does not take effect, look for somebody trying to
override the *same kind of entry* rather than the same file.

**An *added* entry is a different question and is not settled here.** What was
refused was a *redefinition* of a name the base game already owns. Whether a
brand-new `CDrivebyWeaponGroup` name, referenced by a brand-new anim info, is
accepted from an added file was never tested — every add-on vehicle in the wild
relies on exactly that working, which is weak evidence that it does, and weak
evidence is why "Going per-seat" would start with a two-minute experiment rather
than a week of transcription.

---

## Why a seat refuses a rifle at all

**GTA decides which weapons a seat accepts in data, not in code.** The chain is
four links long and every link is a named entry in `vehiclelayouts.meta`:

```
CVehicleLayoutInfo        LAYOUT_STANDARD          which seats a vehicle has
  └─ CVehicleSeatAnimInfo    SEAT_ANIM_STD_PS      one seat
       └─ CVehicleDriveByInfo   DRIVEBY_STD_FRONT_RIGHT   aim arcs, and…
            └─ CVehicleDriveByAnimInfo  STD_DB_ANIM_INFO_ONE_HANDED_PS
                 ├─ WeaponGroup ref  DRIVEBY_DEFAULT_ONE_HANDED
                 └─ DriveByClipSet   the animation the ped plays
```

A seat accepts the **union of the weapon groups named by its anim infos** and
nothing else. A stock car seat reaches `DRIVEBY_DEFAULT_UNARMED`,
`DRIVEBY_DEFAULT_ONE_HANDED` (or `DRIVEBY_DEFAULT_REAR_ONE_HANDED` in the back)
and `DRIVEBY_THROW` — broadly pistols, the small SMGs, fists and thrown weapons.
A rifle, most shotguns, a sniper or an MG is on none of those lists, so the
engine takes it out of the ped's hands on the way into the seat.

`SET_PLAYER_CAN_DO_DRIVE_BY` is not the lever: it is a per-player on/off switch
that defaults to **on**, and `br_core/client/inventory.lua` asserts it on a
cadence anyway. **There is no native that widens a seat's weapon list, and no
native that reads it either** — the engine will only ever tell you about the
weapon already in the ped's hands, by stowing it or not.

The weapon groups the base game defines:

| Group | Reached from |
|---|---|
| `DRIVEBY_DEFAULT_UNARMED` | every seat |
| `DRIVEBY_DEFAULT_ONE_HANDED` | front seats — **driver and front passenger** |
| `DRIVEBY_DEFAULT_REAR_ONE_HANDED` | rear seats |
| `DRIVEBY_DEFAULT_TWO_HANDED` | a handful of special seats |
| `DRIVEBY_HELI_TWO_HANDED`, `DRIVEBY_HELI_RPG` | helicopter cabins — which is why a Maverick passenger *can* fire a rifle |
| `DRIVEBY_BIKE_ONE_HANDED`, `DRIVEBY_BIKE_MELEE` | bikes |
| `DRIVEBY_MOUNTED_THROW`, `DRIVEBY_THROW` | thrown weapons |
| `DRIVEBY_VEHICLE_WEAPON_GROUP` | vehicle-mounted weapons |

---

## What we ship instead

**Nothing the game parses.** `br_environment` ships no data file at all; its
manifest carries a note saying why, so the next person to reach for `data_file`
reads the finding before they write one.

What a passenger gets is a **sentence**, once per session, from
`br_core/client/driveby.lua`:

> Switch to slot *[#]* to fire your *[weapon]* during drive-by shootings.

…shown when they are in a passenger seat, hold a weapon a seat accepts, and do
not already have it selected. The owner's wording, verbatim, with the slot
number and the weapon's label substituted.

### Where "a weapon a seat accepts" comes from

A **`driveby` boolean on every entry in `br_lib/config/weapons.lua`** — in the
weapon table rather than in a list beside it, so there is no second table to
fall out of step with the first.

* **`tools/check_weapons.lua` fails the build** for any weapon or throwable whose
  `driveby` is not an explicit `true`/`false`. A gun added without an answer is
  a red build, not a gun nobody is ever told to switch to. It also fails if a
  *melee* entry carries the field, because no car seat reaches
  `DRIVEBY_BIKE_MELEE` and the answer is "no" for that whole list.
* **No offline gate can check the values**, only their presence — the truth is
  inside the game's `.rpf`. The check on the values is `/brdriveby`, from a
  seat: it prints our claim on the row above what the engine actually did, and
  returns the verdict `stowed-unexpected` when they disagree in the direction
  that matters (a weapon we would have offered, that the engine took away).
* **`false` is the safe direction and unknowns are `false`.** A weapon wrongly
  marked false costs a notification nobody was owed. A weapon wrongly marked
  true sends a player to a slot that does not fire, which is worse than the bug.

### How the ten `true`s were arrived at

**Rockstar's own `DrivebyWeaponGroups` block is not published anywhere.** Even
Rockstar's DLC layout files ship it empty (`<DrivebyWeaponGroups />`), so the
definitions exist only inside `update.rpf`. The answers below are triangulated
from three independent directions, and the agreement between them is the reason
for the confidence — no single source would be enough.

| Evidence | What it gives |
|---|---|
| **The playtest**, 2026-08-22 | pistols fire from a passenger seat; the carbine does not. Two weapons, certain. |
| [citizenfx/fivem#3929](https://github.com/citizenfx/fivem/issues/3929) | *"Micro SMGs & Machine Pistols (both GROUP_SMG) can be used in cars for drive-by"* — and custom weapons in `GROUP_SMG` **cannot**, which proves the group is named weapon-by-weapon rather than as `GROUP_SMG`. A contributor adds that `GROUP_PISTOL` works *"since the default layouts file allows drive-by for that whole group"*. |
| **The GTA wiki's motorcycle list** | the weapons that are *bike-only* precisely because they do not work in cars: *"the SMG, SMG Mk II, the Sawed-Off Shotgun, Double Barrel Shotgun, Sweeper Shotgun, Compact Rifle, and the Compact Grenade Launcher."* Corroborated per weapon: the SMG page says *"One cannot use the SMG in a drive-by shooting, as the gun is too large"*, the Assault SMG page says it *"is unable to be used for drive-bys"*, and the Sawed-Off page says it works *"in a limited range of vehicles, namely motorcycles."* |

So the car set is `GROUP_PISTOL` plus a short list of individually named
weapons — which, of the guns this gamemode issues, is:

| `driveby = true` | Why |
|---|---|
| all seven pistols and revolvers | `GROUP_PISTOL`, named as a whole group; and the playtest |
| Micro SMG, Machine Pistol | named outright in #3929 |
| Mini SMG | absent from the bike-only list, and grouped with the other two by every published copy of a one-handed group |
| the four throwables | `DRIVEBY_THROW`, which every standard seat reaches |

Everything else is `false`. **The weakest of these is the Mini SMG** — its case
is an absence of counter-evidence rather than a statement — and the Combat PDW is
`false` for the same reason in the other direction: no source either way, so it
stays quiet.

### Checking it worked

`/brdriveby` from the seat, holding the weapon in question:

* `VERDICT [armed]` — the engine is letting you hold it in this seat, and our
  table agrees. Nothing about the seat is stopping you firing.
* `VERDICT [stowed]` — the seat's stock rule took the weapon. Expected for a
  rifle; the readout names which slot the hint would have offered.
* `VERDICT [stowed-unexpected]` — **our table is wrong.** We claim this seat
  accepts the weapon and the engine stowed it anyway. Set that weapon's
  `driveby` to `false` and note which seat and which vehicle.
* The `we say the seat` row and the `drive-by hint` row print our claim and the
  exact sentence a player would see, so the notice can be read without waiting
  for the one time a session it fires.

---

## Add-on vehicles

An add-on vehicle normally arrives with its own `vehiclelayouts.meta`. That file
is *adding* layouts, seats and anim infos of its own rather than restating
Rockstar's, which is the case that works — see the finding at the top for the
case that does not.

We ship no override for it to interact with, so **there is nothing to reconcile
and this section is a mounting template only.**

### Mount their file, in the right order

In the add-on's own `fxmanifest.lua` — keep third-party data in the third-party
resource:

```lua
files {
    'data/vehiclelayouts.meta',
    'data/handling.meta',
    'data/vehicles.meta',
    'data/carvariations.meta',
}

-- ORDER MATTERS: layouts before vehicles.meta, and vehicles.meta LAST.
-- A vehicle whose layout has not been parsed when its model info is read is a
-- crash on entry, not a warning.
data_file 'VEHICLE_LAYOUTS_FILE'  'data/vehiclelayouts.meta'
data_file 'HANDLING_FILE'         'data/handling.meta'
data_file 'CARCOLS_FILE'          'data/carcols.meta'
data_file 'VEHICLE_VARIATION_FILE' 'data/carvariations.meta'
data_file 'VEHICLE_METADATA_FILE' 'data/vehicles.meta'
```

### Find out which weapon group its seats reach

```bash
grep -n 'WeaponGroup ref' path/to/addon/data/vehiclelayouts.meta | sort -u
```

**If it names the stock groups** (`DRIVEBY_DEFAULT_ONE_HANDED`,
`DRIVEBY_THROW`), its seats behave exactly like every other car in the game and
`br_lib/config/weapons.lua`'s `driveby` answers are already right for it.

**If it defines and names its own group** — say `DRIVEBY_MYPACK_ONE_HANDED` —
then that vehicle's seats have their own weapon list, and it may be narrower or
wider than stock. Our claim is a single answer for "a standard car seat", so a
vehicle with a bespoke group is the one case where the hint can be wrong in one
vehicle and right everywhere else, which is the hardest kind of bug to notice.
The cheap fix is to repoint its seats at the stock group:

```bash
sed -i 's/DRIVEBY_MYPACK_ONE_HANDED/DRIVEBY_DEFAULT_ONE_HANDED/g' \
    path/to/addon/data/vehiclelayouts.meta
```

Then delete the now-unreferenced `<Item type="CDrivebyWeaponGroup">` block and
re-run the grep. If their group differs by more than its weapon list — different
aim arcs, a bespoke clip set — repointing throws that away; in that case leave it
alone and sit in each of its seats with `/brdriveby` instead.

### Prove it, per vehicle

Spawn the add-on, sit in each of its passenger seats and run `/brdriveby`. The
seat row names the seat; the verdict names the cause. `stowed-unexpected` in one
vehicle and `armed` in every other is a bespoke weapon group.

### Licensing

Take nothing from a paid, escrowed or unlicensed resource — a `.meta` inside an
`escrow_ignore` block is escrowed even though the file itself is readable. If an
add-on is vendored, its licence goes in `VENDOR.json` alongside it and
`verify.sh`'s vendored-third-party gate checks that both directions agree.

---

## Going per-seat

**The only route left**, and nobody has decided it is worth taking. It is here so
the cost is on record rather than rediscovered.

The redefinition route died because the game will not let an added file restate a
group it already owns. Adding *new* names may well work — every add-on vehicle
depends on new layouts being accepted — so the route is: **add**, never redefine.

1. **Spend two minutes before spending a week.** Author one new
   `CDrivebyWeaponGroup` under a name the base game has never heard of, one new
   `CVehicleDriveByAnimInfo` naming it, and one new `CVehicleDriveByInfo` for a
   single seat of a single vehicle. If a rifle fires from that seat, the route is
   open. If it does not, the whole idea is dead and this section can be deleted.
2. Only then: extract Rockstar's `vehiclelayouts.meta` from the game install with
   OpenIV (`update.rpf/common/data/`, plus one per DLC pack — there are dozens).
3. For every `CVehicleDriveByInfo` belonging to a **non-driver** seat, note the
   `_PS`, `_RDS` and `_RPS` anim infos it lists.
4. Author a new anim info per seat that names the new weapon group and **reuses
   that seat's existing `DriveByClipSet` verbatim** — the clip set is the part
   that must not be invented, and a wrong one is how a drive-by turns into a
   broken pose.
5. Redefine each of those `CVehicleDriveByInfo` entries with the new anim info
   appended to its list.

**Step 5 is a redefinition, and step 1 does not test it.** Every
`CVehicleDriveByInfo` in the base game already exists, so this route ends up
asking the mounter for the same favour that was just refused, one link further
down the chain. Whether the answer differs there is unknown; assume it does not
until a seat proves otherwise.

Every redefinition is also Rockstar data restated, so from that point on the file
must be re-checked against every game build — the maintenance the original
two-entry design existed to avoid, now unavoidable.

### The two routes that are documented to work, and why neither is ours

**Re-group the weapon in `weapons.meta`.** Setting a weapon's `<Group>` to
`GROUP_PISTOL` makes it drive-by capable, because the stock one-handed group
names that whole group. Two participants in
[#3929](https://github.com/citizenfx/fivem/issues/3929) confirm it works, with
the side effects stated:

> "the only consequences end up being game balance, as firing weapons from within
> vehicles use different recoil, fire rate, etc. You'd also have 'visual' issues
> where someone is shooting a rifle or other large weapons with one hand"

**It does not apply here.** `weapons.meta` has the *same* override problem, so
this only reaches weapons whose `weapons.meta` you own — add-on weapons. Every
gun this gamemode issues is a stock GTA weapon, and re-grouping a stock weapon is
the thing that cannot be done.

**Author your own layouts end to end.** The reporter's own working proof of
concept: a custom copy of every layout their vehicles use, seat infos included,
with each vehicle repointed at it in `vehicles.meta`. That is the enormous file,
and it is what "Going per-seat" above turns into.

**The cheap alternative, for completeness:** `SetPlayerCanDoDriveBy(PlayerId(),
false)` while the player is in seat `-1` gives the owner's *"any seat which is
not the driver"* by taking the drive-by away from the driver rather than giving
it to anyone. It costs the driver the pistol drive-by they have today, so it is a
regression traded for a restriction and is deliberately not shipped.

---

## Nothing here is readable at runtime either

There is **no native** that answers "does this seat accept this weapon" or "which
`CDrivebyWeaponGroup` does this seat use". Every drive-by native the platform
has is about *doing* a drive-by, not about permission:
`TASK_DRIVE_BY`, `SET_DRIVEBY_TASK_TARGET`,
`IS_DRIVEBY_TASK_UNDERNEATH_DRIVING_TASK`,
`CLEAR_DRIVEBY_TASK_UNDERNEATH_DRIVING_TASK`, `IS_PED_DOING_DRIVEBY`,
`SET_PED_DRIVE_BY_CLIPSET_OVERRIDE`, `CLEAR_PED_DRIVE_BY_CLIPSET_OVERRIDE`,
`SET_PLAYER_CAN_DO_DRIVE_BY`, `GET_IS_USING_ALTERNATE_DRIVEBY`.
`GET_VEHICLE_LAYOUT_HASH` returns a layout hash and nothing you can resolve.

The only runtime signal is indirect and applies to one weapon at a time: **the
engine stows what a seat refuses**, so `GET_CURRENT_PED_WEAPON` answering
`WEAPON_UNARMED` while our own grant says otherwise *is* the refusal. That is
what `/brdriveby` samples, and it is why the `driveby` field exists rather than
a lookup.

`GET_WEAPONTYPE_GROUP` (`0xC3287EE3050FB74C`) does exist and returns the
weapon's `GROUP_*` — `GROUP_PISTOL` is `416676503` — which would let the pistol
half of the table be derived rather than written. It is deliberately not used:
one mechanism that is right for seven weapons and silent about the other
twenty-nine is harder to audit than one table `/brdriveby` checks a row at a
time.

---
