# Vehicle data overrides

The one file in this repository the *game* parses instead of us — what it
changes, what it deliberately does not, and how to fold an add-on vehicle's own
copy into it.

[← Back to the main README](../README.md)

---

## Why there is a data file here at all

A passenger could not fire a rifle from a car seat (#197), and no amount of Lua
was ever going to fix it. **GTA decides which weapons a seat accepts in data.**
The chain is four links long and every link is a named entry in
`vehiclelayouts.meta`:

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
`DRIVEBY_DEFAULT_ONE_HANDED` and `DRIVEBY_THROW` — pistols, the small SMGs,
fists and thrown weapons. A rifle, shotgun, sniper or MG is on none of those
lists, so the engine takes it out of the ped's hands on the way into the seat.

`SET_PLAYER_CAN_DO_DRIVE_BY` is not the lever: it is a per-player on/off switch
that defaults to **on**, and `br_core/client/inventory.lua` asserts it on a
cadence anyway. There is no native that widens a seat's weapon list.

The eleven weapon groups the base game defines are:

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

## What we actually ship

`resources/[fivem-royale]/br_environment/data/vehiclelayouts.meta`, mounted by
that resource's manifest as:

```lua
files { 'data/vehiclelayouts.meta' }
data_file 'VEHICLE_LAYOUTS_FILE' 'data/vehiclelayouts.meta'
```

It redefines **two entries and nothing else** —
`DRIVEBY_DEFAULT_ONE_HANDED` and `DRIVEBY_DEFAULT_REAR_ONE_HANDED` — so their
weapon list becomes every firearm in `br_lib/config/weapons.lua`. No layout, no
seat, no entry point, no drive-by info, no clip set and no aim angle is
restated.

**That smallness is the whole design, not a shortcut.** The obvious way to do
this — and the way most published "enable drive-by" resources do it — is to
ship a copy of Rockstar's own `vehiclelayouts.meta` with the weapon lists
edited. That copy is tens of thousands of lines; it redistributes Rockstar's
data; it is stale the day a game build changes a seat; and when it goes stale
the symptom is one vehicle quietly behaving like last year's. Two named entries
have none of those properties, because **there is no Rockstar data in the file
to fall out of date.** Every clip set, arc and seat still comes from the game.

### The maintenance this hands you

Almost none, and it is worth being precise about what "almost" covers:

* **Add a gun to `br_lib/config/weapons.lua` and you must add it to the
  `.meta`.** The list *replaces* the base game's rather than extending it, so a
  weapon left off does not keep its old behaviour — it loses drive-by outright,
  silently. `tools/check_driveby.lua` fails the build in both directions, so in
  practice this is a red build rather than a bug.
* **A game build that renames either group** would make our entries dangling
  additions that nothing references. Nothing breaks; the seat rule simply goes
  back to stock, and `/brdriveby` says so.
* **Nothing else.** There is no per-vehicle list to keep, no seat table, no clip
  set names to chase.

### What it does to the driver, and why

The owner asked for *"any seat which is not the driver"* (2026-08-06). **This
change reaches the driver too**, and that is a property of the game's data
rather than a decision taken here: the driver's seat and the front passenger's
seat name the *same* weapon group, `DRIVEBY_DEFAULT_ONE_HANDED`. There is no
edit to that list which reaches one and not the other.

Separating them means going one link further down the chain — giving the
passenger seats their own `CVehicleDriveByAnimInfo` pointing at a new group, and
leaving the driver's on the stock one. That means redefining the per-seat
`CVehicleDriveByInfo` for every vehicle class in the game, which means restating
Rockstar's clip set names for each of them, which is the enormous stale file
this design exists to avoid. It is a real option and it is written up in
["Going per-seat"](#going-per-seat) below — it is just not a small one.

The cheap alternative, if the driver turns out to matter more than the
maintenance: `SetPlayerCanDoDriveBy(PlayerId(), false)` while the player is in
seat `-1`. It costs the driver their **pistol** drive-by as well, which they
have today, so it is a regression traded for a restriction and is deliberately
not shipped.

### What it does to the animation

Clip sets live on the anim info, which this file does not touch. So a rifle
fired from a passenger seat plays that seat's existing **one-handed** drive-by
animation: held in one hand, swept through the arc a pistol uses. It is not a
two-handed rifle pose and will not look like one.

It is **not** a missing clip set, so it is not a T-pose — the animation exists
and is fully populated; only the weapon model in the hand is larger than the
pose was authored for. How good that looks is a judgement that can only be made
in game.

### Checking it worked

`/brdriveby` from the seat, holding the weapon in question. It reads the
override back off the client with `LoadResourceFile` and reports:

* `NOT READABLE` — the file never reached this client. A deploy problem;
  `br_environment` is probably not started.
* `READ BACK … names WEAPON_X yes` plus verdict `armed` — it worked.
* `READ BACK … names WEAPON_X yes` plus verdict `override-ignored` — the game
  kept its own copy of the entry and ignored ours. **This is the one thing the
  desk could not settle**: whether a mounted data file may redefine a name the
  base game already has is not documented and community reports disagree. It
  fails safe — the seat keeps today's rule — but if this is the verdict, the
  weapon-group route is dead and only the per-seat route below remains.
* `names WEAPON_X NO` plus verdict `stowed-unlisted` — the weapon is missing
  from our list, which also means `tools/check_driveby.lua` has a hole in it.

---

## Add-on vehicles

An add-on vehicle normally arrives with its own `vehiclelayouts.meta`. Ours and
theirs are both *added* files — neither replaces the other — so the two coexist,
and the only question is **which weapon group the add-on's seats name**. There
are exactly two answers and one of them needs no work at all.

### Step 1 — mount their file at all

In the add-on's own `fxmanifest.lua` (not ours — keep third-party data in the
third-party resource):

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

### Step 2 — find out which weapon group its seats reach

```bash
grep -n 'WeaponGroup ref' path/to/addon/data/vehiclelayouts.meta | sort -u
```

**Case A — it names the stock groups.** Output looks like:

```
<WeaponGroup ref="DRIVEBY_DEFAULT_ONE_HANDED" />
<WeaponGroup ref="DRIVEBY_THROW" />
```

**Nothing to do.** Our override redefines those groups, so the add-on's seats
inherit the widened list for free. This is the common case; most add-ons reuse
Rockstar's groups because writing your own buys nothing.

**Case B — it defines and names its own group.** Output looks like:

```
<WeaponGroup ref="DRIVEBY_MYPACK_ONE_HANDED" />
```

and somewhere in the file there is a matching definition:

```xml
<DrivebyWeaponGroups>
  <Item type="CDrivebyWeaponGroup">
    <Name>DRIVEBY_MYPACK_ONE_HANDED</Name>
    <WeaponGroupNames>
      <Item>GROUP_PISTOL</Item>
    </WeaponGroupNames>
    <WeaponTypeNames>
      <Item>WEAPON_MICROSMG</Item>
    </WeaponTypeNames>
  </Item>
</DrivebyWeaponGroups>
```

Our file does not touch that name, so those seats keep the narrow list and a
passenger in that vehicle still cannot fire a rifle — in one vehicle, which is
the hardest kind of bug to notice.

**The fix is one line per anim info: repoint the seats at the stock group.**
Prefer this over editing their weapon list, because it leaves exactly one list
in the repository to maintain rather than two that must be kept identical.

```bash
sed -i 's/DRIVEBY_MYPACK_ONE_HANDED/DRIVEBY_DEFAULT_ONE_HANDED/g' \
    path/to/addon/data/vehiclelayouts.meta
```

Then delete the now-unreferenced `<Item type="CDrivebyWeaponGroup">` block, and
re-run the grep above to confirm only stock group names remain.

> **If their group differs by more than its weapon list** — different aim arcs,
> a bespoke clip set — repointing throws that away. In that case edit *their*
> `<WeaponTypeNames>` instead and copy the weapon list out of
> `br_environment/data/vehiclelayouts.meta` verbatim. `tools/check_driveby.lua`
> does not check third-party files, so this is the one case that has to be
> remembered by hand; say so in the add-on's own `VENDOR.json` notes.

### Step 3 — prove it, per vehicle

Spawn the add-on, sit in each of its passenger seats with a rifle, and run
`/brdriveby`. The seat row names the seat; the verdict names the cause. A
vehicle where only the *rear* seats fail means its rear seats reach
`DRIVEBY_DEFAULT_REAR_ONE_HANDED` and something in the add-on is shadowing it.

### Licensing

Take nothing from a paid, escrowed or unlicensed resource — a `.meta` inside an
`escrow_ignore` block is escrowed even though the file itself is readable. If an
add-on is vendored, its licence goes in `VENDOR.json` alongside it and
`verify.sh`'s vendored-third-party gate checks that both directions agree.

---

## Going per-seat

Only if `/brdriveby` returns `override-ignored`, or the owner decides the driver
must keep the stock rule. This is the large option and the cost is real.

1. Extract Rockstar's `vehiclelayouts.meta` from the game install with OpenIV
   (`update.rpf/common/data/`, plus one per DLC pack — there are dozens).
2. For every `CVehicleDriveByInfo` belonging to a **non-driver** seat, note the
   `_PS`, `_RDS` and `_RPS` anim infos it lists.
3. Author a new `CDrivebyWeaponGroup` (e.g. `BR_DRIVEBY_PASSENGER`) with our
   weapon list, and a new `CVehicleDriveByAnimInfo` per seat that names it and
   **reuses that seat's existing `DriveByClipSet` verbatim** — the clip set is
   the part that must not be invented, and a wrong one is how a drive-by turns
   into a broken pose.
4. Redefine each of those `CVehicleDriveByInfo` entries with the new anim info
   appended to its `DriveByAnimInfos` list.

Every one of those redefinitions is Rockstar data restated, so from that point
on the file must be re-checked against each game build. `tools/check_driveby.lua`
refuses any section other than `<DrivebyWeaponGroups>` precisely so this cannot
happen by accident — taking that route means changing the gate first, on
purpose, with the maintenance written down.

---
