#!/usr/bin/env python3
"""Every base-game vehicle model and vehicle weapon (#426), from the game's own data.

    py tools/vehicle_models.py <vehicles.json>            write both tables
    py tools/vehicle_models.py <vehicles.json> --check    say whether they are current

WHAT IT READS. DurtyFree's dump of the game's vehicle data
(github.com/DurtyFree/gta-v-data-dumps, vehicles.json; game build 3717 when this
was first run): one object per vehicle model the game registers, with its type,
its bounding box and the vehicle weapons its data lists.

WHAT IT WRITES. resources/[fivem-royale]/br_lib/config/vehicle_models.lua, the
one table that says what the server knows about a model without asking a
client (BR.Config.VehicleModels): one row per model, in name order,
`{ name, hash, tree, reach, below, front, rear, armed, jerryFills }`.

  * name   the model name, lower case: what GetHashKey hashes.
  * hash   the game's own hash for it, which must be joaat(name) -- a name the
           hash does not come from is refused, so no row is a guess at a spelling.
  * tree   the sync tree CreateVehicleServerSetter has to build it as: the one
           FiveM's client accepts for its vehicle type (gta-net-five's
           netSyncTree.cpp, CVehicleCreationDataNode__CanApply). A car, a quad,
           an amphibious car or quad and a submarine car are `automobile`; a
           bike and a bicycle `bike`; a heli and a blimp `heli`; and boat,
           plane, submarine, trailer and train are themselves.
  * reach  how far it reaches out from its origin across its width, on the
           wider side, in meters rounded UP to a tenth -- the side a spawn turned
           a quarter across puts toward the player.
  * below  how far its bottom sits below its origin, in meters rounded UP.
  * front  how far it reaches ahead of its origin along its length, and
  * rear   how far behind it, both in meters rounded UP (#217): the Season 2
           jerry can's server bound is the footprint these two and `reach`
           describe, in the vehicle's own frame.
           All four sizes are left out for a model the data has no bounding
           box for, and are never written one without the others.
  * armed  true when the data lists a vehicle weapon on it -- a searchlight, a
           radar and a water cannon are not weapons -- except on the one model
           whose listed weapon its own model does not carry: `insurgent2`, the
           plain Insurgent (UNARMED, below). tools/check_vehicles.lua holds
           config/vehicles.lua's "Armed" set to exactly these.
  * jerryFills  true when a jerry can fills its tank whole rather than adding a
           quarter (#217): the game's own quad bikes (its QUADBIKE and
           AMPHIBIOUS_QUADBIKE types, the three trikes among them), dirt bikes
           and dune buggies (JERRY_LAYOUTS) -- the RC Bandito aside (JERRY_NOT).
           True or absent, like `armed`. tools/check_vehicles.lua holds these
           rows to the owner's 26, by name.

AND resources/[fivem-royale]/br_lib/config/vehicle_weapons.lua (#426's second
review): every vehicle weapon the data lists on any model, the searchlight, the
radar and the water cannon among them, each `{ name, hash }` with the hash
joaat(name) -- BR.Config.VehicleWeapons, and BR.Config.VehicleWeaponByHash
keyed by it. A dev menu vehicle's gun is excused for these weapons and no other,
on both sides, so unlike the model table it is a shared script.

NEITHER IS EDITED BY HAND, AND A HAND EDIT IS CAUGHT. Each file's header carries
an FNV-1a (32-bit) of its body -- every byte from `BR = BR or {}` to the end --
and tools/check_vehicles.lua recomputes it, so a tree, a size, an armed flag or
a weapon changed by hand fails there without the dump.

Anything malformed is refused whole and nothing is written: a model with no
name, a name that is not a model word, a type this table has no tree for, a
hash that is not the name's, a name or a hash twice, a bounding box that is not
six finite numbers, a layout that is not a name, or a weapon that is not a
VEHICLE_WEAPON_ name. So is a dump in which the UNARMED override's reason no
longer holds, or in which the RC Bandito is no longer in the jerry can's rule
for JERRY_NOT to leave it out of -- see each.
"""

import argparse
import hashlib
import json
import math
import os
import re
import sys

OUT = os.path.join('resources', '[fivem-royale]', 'br_lib', 'config', 'vehicle_models.lua')
WEAPONS_OUT = os.path.join('resources', '[fivem-royale]', 'br_lib', 'config', 'vehicle_weapons.lua')
MODEL = re.compile(r'^[a-z0-9_]{1,64}$')
WEAPON = re.compile(r'^VEHICLE_WEAPON_[A-Z0-9_]{1,64}$')

#: Where a file's body begins: the checksum covers every byte from here on.
BODY = 'BR = BR or {}\n'

#: The vehicle type each tree accepts, as netSyncTree.cpp checks it (the
#: automobile list is the one it keeps commented out: nothing is swapped there).
TREE = {
    'CAR': 'automobile', 'QUADBIKE': 'automobile', 'SUBMARINECAR': 'automobile',
    'AMPHIBIOUS_AUTOMOBILE': 'automobile', 'AMPHIBIOUS_QUADBIKE': 'automobile',
    'BIKE': 'bike', 'BICYCLE': 'bike',
    'BOAT': 'boat',
    'HELI': 'heli', 'BLIMP': 'heli',
    'PLANE': 'plane',
    'SUBMARINE': 'submarine',
    'TRAILER': 'trailer',
    'TRAIN': 'train',
}

#: Listed among a model's weapons, and not one.
NOT_WEAPONS = {'VEHICLE_WEAPON_SEARCHLIGHT', 'VEHICLE_WEAPON_RADAR', 'VEHICLE_WEAPON_WATER_CANNON'}

#: A model the data gives a vehicle weapon that its own model does not carry,
#: and so not `armed`, whatever its weapons say (#427). One, by name.
#:
#: `insurgent2` IS THE PLAIN INSURGENT, armored and with no gun. The data lists
#: VEHICLE_WEAPON_TURRET_INSURGENT on it AND on `insurgent`, the Insurgent
#: Pick-Up -- but only the Pick-Up's model carries the turret: it has the
#: turret_1base, turret_1barrel and weapon_1a bones (so does `insurgent3`, the
#: Pick-Up Custom, with a minigun's beside them), and insurgent2's has no bone
#: starting turret_ or weapon_ at all. A gun with nowhere on the model to sit is
#: no gun.
#:
#: THE REASON IS ASSERTED ON EVERY RUN, NOT TRUSTED (`unarmed_holds`), so a
#: newer dump cannot keep a stale override: one that shows the model a turret_
#: or weapon_ bone, shows it no skeleton to look in, or no longer gives it a
#: weapon to override is refused whole, and nothing is written.
#:
#: NOT A BONE RULE, AND IT MUST NOT BECOME ONE. `ignus2`, the Weaponized Ignus,
#: is really armed, and its skeleton names no turret_ or weapon_ bone either --
#: the dump holds only a stub for it. "No gun bone, no gun" would unarm it. An
#: override is one model, by name, with its reason checked.
UNARMED = {'insurgent2'}

#: The root bone of every vehicle skeleton the dump could read. A model it could
#: not read has a single `stub` bone instead (`ignus2` is one), and a skeleton
#: like that proves nothing about where a gun would go.
SKELETON = 'chassis'

#: The Season 2 jerry can (#217) FILLS the tank of these and adds a quarter of
#: one to anything else. Owner, 2026-08-22: "for 4wheelers/buggies/dirtbikes it
#: should fill the tank completely"; on 2026-11-02 he picked the 26 models of
#: the game's own quad, dirt-bike and dune-buggy groups from a list. THE RULE IS
#: THE GAME'S GROUPING: its quad-bike types (the three trikes -- Chimera,
#: Rampant Rocket, Stryder -- are typed as quads), its two dirt-bike layouts and
#: its five dune-buggy layouts. A rule on layouts alone would be wrong both
#: ways: the trikes share their layouts with road bikes (ratbike, wolfsbane and
#: seventeen sport bikes).
JERRY_TYPES = {'QUADBIKE', 'AMPHIBIOUS_QUADBIKE'}
JERRY_LAYOUTS = {
    'LAYOUT_BIKE_DIRT', 'LAYOUT_BIKE_MANCHEZ2',                       # dirt bikes
    'LAYOUT_LOW_DUNE', 'LAYOUT_LOW_DUNE3', 'LAYOUT_LOW_BFINJECTION',   # dune buggies
    'LAYOUT_STD_OUTLAW', 'LAYOUT_LOW_VAGRANT',
}

#: In the jerry can's rule and not one of the owner's 26, and so not
#: `jerryFills`, by name. One: `rcbandito`, the RC Bandito, a remote-control toy
#: car in a dune-buggy layout (LAYOUT_LOW_DUNE, beside the Bifta and the Dune
#: Buggy). The owner's 26 do not name it.
#:
#: CHECKED ON EVERY RUN, LIKE UNARMED: a dump that no longer puts it in the rule
#: -- or no longer has it -- leaves an exclusion that excludes nothing, and is
#: refused whole, with nothing written.
JERRY_NOT = {'rcbandito'}


def joaat(s):
    """Jenkins one-at-a-time over the lower-cased name, as GTA hashes a model."""
    h = 0
    for c in s.lower().encode('utf-8'):
        h = (h + c) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h ^= h >> 6
    h = (h + (h << 3)) & 0xFFFFFFFF
    h ^= h >> 11
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h


def fnv1a(data):
    """FNV-1a, 32-bit, over bytes: what tools/check_vehicles.lua recomputes."""
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def with_checksum(header, body):
    """The file: its header, the body's checksum, a blank line and the body."""
    assert body.startswith(BODY)
    return '\n'.join(header + [
        "-- Body FNV-1a 0x%08X: every byte from `BR = BR or {}` to the end, which"
        % fnv1a(body.encode('utf-8')),
        "-- tools/check_vehicles.lua recomputes -- so a row changed by hand fails there.",
    ]) + '\n\n' + body


def tenth_up(v):
    """Meters, rounded UP to a tenth: a placement read off it clears the model."""
    return math.ceil(round(v * 10.0, 6)) / 10.0


def finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def unarmed_holds(name, v):
    """Raises ValueError unless the dump still shows why `name` is UNARMED: a
    skeleton it could read, with no bone starting turret_ or weapon_ in it."""
    bones = v.get('Bones')
    seen = []
    for b in bones if isinstance(bones, list) else []:
        n = b.get('BoneName') if isinstance(b, dict) else None
        if isinstance(n, str):
            seen.append(n.lower())
    if SKELETON not in seen:
        raise ValueError('%s: the data shows no skeleton for it, so nothing says it has '
                         'no gun -- its UNARMED override cannot be checked' % name)
    gun = [n for n in seen if n.startswith(('turret_', 'weapon_'))]
    if gun:
        raise ValueError('%s: the data now gives its model %s, so it may carry a gun '
                         'after all -- its UNARMED override is stale' % (name, ', '.join(gun)))


def rows_of(doc):
    """The rows, checked, in name order, or raises ValueError naming the first fault."""
    if not isinstance(doc, list) or not doc:
        raise ValueError('not a list of vehicle models')
    out, names, hashes, overridden, excepted = [], set(), set(), set(), set()
    for i, v in enumerate(doc, 1):
        if not isinstance(v, dict):
            raise ValueError('entry %d is not an object' % i)
        raw = v.get('Name')
        if not isinstance(raw, str) or not MODEL.match(raw.lower()):
            raise ValueError('entry %d: %r is not a model name' % (i, raw))
        name = raw.lower()
        typ = v.get('Type')
        if typ not in TREE:
            raise ValueError('%s: type %r has no sync tree here' % (name, typ))
        h = v.get('Hash')
        if not (isinstance(h, int) and not isinstance(h, bool)):
            raise ValueError('%s: hash %r is not a number' % (name, h))
        h &= 0xFFFFFFFF
        if joaat(name) != h:
            raise ValueError('%s: the data says 0x%08X, the name hashes to 0x%08X'
                             % (name, h, joaat(name)))
        if name in names or h in hashes:
            raise ValueError('%s: twice' % name)
        names.add(name)
        hashes.add(h)

        row = {'name': name, 'hash': h, 'tree': TREE[typ]}
        mn, mx = v.get('DimensionsMin'), v.get('DimensionsMax')
        if mn is not None or mx is not None:
            try:
                box = [mn['X'], mn['Y'], mn['Z'], mx['X'], mx['Y'], mx['Z']]
            except (TypeError, KeyError):
                raise ValueError('%s: a bounding box with a corner missing' % name)
            if not all(finite(b) for b in box):
                raise ValueError('%s: a bounding box that is not six numbers' % name)
            row['reach'] = tenth_up(max(abs(mn['X']), abs(mx['X'])))
            row['below'] = tenth_up(max(0.0, -mn['Z']))
            row['front'] = tenth_up(max(0.0, mx['Y']))
            row['rear'] = tenth_up(max(0.0, -mn['Y']))
        weapons = v.get('Weapons') or []
        if not isinstance(weapons, list):
            raise ValueError('%s: weapons %r is not a list' % (name, weapons))
        if any(w not in NOT_WEAPONS for w in weapons):
            if name in UNARMED:
                unarmed_holds(name, v)
                overridden.add(name)
            else:
                row['armed'] = True
        layout = v.get('LayoutId')
        if layout is not None and not isinstance(layout, str):
            raise ValueError('%s: layout %r is not a name' % (name, layout))
        if typ in JERRY_TYPES or layout in JERRY_LAYOUTS:
            if name in JERRY_NOT:
                excepted.add(name)
            else:
                row['jerryFills'] = True
        out.append(row)
    # AN OVERRIDE THAT OVERRODE NOTHING IS STALE TOO: the dump no longer has the
    # model, or no longer gives it a weapon. Either way nothing checks it now.
    stale = sorted(UNARMED - overridden)
    if stale:
        raise ValueError('%s: the data gives it no weapon to override, or does not have '
                         'it -- its UNARMED override is stale' % ', '.join(stale))
    # AND AN EXCLUSION THAT EXCLUDED NOTHING (#217): the dump no longer puts the
    # model in a quad type, a dirt-bike layout or a dune-buggy layout, or no
    # longer has it. Either way the reason written beside JERRY_NOT is no longer
    # what the data says, and a table written from it would be a guess.
    stale = sorted(JERRY_NOT - excepted)
    if stale:
        raise ValueError('%s: the data puts it in no quad type, dirt-bike layout or '
                         'dune-buggy layout, or does not have it -- its JERRY_NOT '
                         'exclusion is stale' % ', '.join(stale))
    out.sort(key=lambda r: r['name'])
    return out


def weapons_of(doc):
    """Every vehicle weapon any model lists, checked, as (name, hash) in name order."""
    out = {}
    for v in doc:
        for w in v.get('Weapons') or []:
            if not isinstance(w, str) or not WEAPON.match(w):
                raise ValueError('%s: %r is not a vehicle weapon name' % (v.get('Name'), w))
            out[w] = joaat(w)
    seen = {}
    for name, h in out.items():
        if h in seen:
            raise ValueError('%s and %s hash alike' % (seen[h], name))
        seen[h] = name
    if not out:
        raise ValueError('no model lists a vehicle weapon')
    return sorted(out.items())


def render_weapons(weapons, digest):
    width = max(len(n) for n, _ in weapons) + 3
    header = [
        "-- Every vehicle weapon in the base game (#426): WRITTEN BY tools/vehicle_models.py",
        "-- FROM THE GAME'S OWN VEHICLE DATA, NOT EDITED. Each weapon the data lists on",
        "-- any model -- the searchlight, the radar and the water cannon among them --",
        "-- with its hash, which is joaat of its name.",
        "--",
        "-- What reads it: the excuse for a dev menu vehicle's own gun, which covers",
        "-- these weapons and no other -- server/damage.lua and server/strip.lua ask it,",
        "-- and so does client/inventory.lua's strip, which is why this is a shared",
        "-- script while config/vehicle_models.lua is the server's alone -- and",
        "-- tools/check_vehicles.lua, which re-derives every hash. Every model's",
        "-- weapons, not each model's own: an add-on that mounts a gun of the base",
        "-- game is excused as well.",
        "--",
        "-- To change a row, run the tool again on a newer dump:",
        "--     py tools/vehicle_models.py <path to vehicles.json>",
        "--",
        "-- Source: vehicles.json, %d vehicle weapons, sha256 %s" % (len(weapons), digest),
    ]
    body = [
        "BR = BR or {}",
        "BR.Config = BR.Config or {}",
        "",
        "BR.Config.VehicleWeapons = {",
    ]
    for name, h in weapons:
        body.append("    { name = %s hash = 0x%08X }," % (("'%s'," % name).ljust(width), h))
    body += [
        "}",
        "",
        "--- [hash] = name, keyed by the UNSIGNED hash: a native's answer is signed, so",
        "--- it goes through BR.NormHash before it is looked up here.",
        "BR.Config.VehicleWeaponByHash = {}",
        "for _, w in ipairs(BR.Config.VehicleWeapons) do",
        "    BR.Config.VehicleWeaponByHash[w.hash] = w.name",
        "end",
    ]
    return with_checksum(header, '\n'.join(body) + '\n')


def render(rows, digest):
    width = max(len(r['name']) for r in rows) + 3
    trees = {}
    for r in rows:
        trees[r['tree']] = trees.get(r['tree'], 0) + 1
    armed = sum(1 for r in rows if r.get('armed'))
    jerry = sum(1 for r in rows if r.get('jerryFills'))
    header = [
        "-- Every base-game vehicle model (#426): WRITTEN BY tools/vehicle_models.py",
        "-- FROM THE GAME'S OWN VEHICLE DATA, NOT EDITED. One row per model the game",
        "-- registers: its name and the game's hash for it; the sync tree",
        "-- CreateVehicleServerSetter has to build it as; how far it reaches across",
        "-- its width (`reach`), below its origin (`below`), ahead of it (`front`) and",
        "-- behind it (`rear`), in meters rounded up; `armed` where the data lists a",
        "-- vehicle weapon on it, the plain Insurgent (`insurgent2`) aside: its model",
        "-- has no gun (the tool's UNARMED); and `jerryFills` where a jerry can fills",
        "-- the tank whole (#217): the game's quads, dirt bikes and dune buggies, the",
        "-- RC Bandito -- a remote-control toy in a buggy layout -- left out (JERRY_NOT).",
        "--",
        "-- What reads it, and nothing else does: server/vehicles.lua's spawn, which",
        "-- builds a model the game has only as its own tree and puts a big one clear",
        "-- of the player; the Season 2 jerry can (server/jerrycan.lua, #217), which",
        "-- bounds a pourer by the footprint and fills a `jerryFills` tank whole; and",
        "-- tools/check_vehicles.lua, which re-derives every hash, holds",
        "-- config/vehicles.lua's \"Armed\" set to the `armed` rows and the `jerryFills`",
        "-- rows to the owner's 26. A model with no row -- an add-on -- is one the",
        "-- server takes the asker's word for. The game's vehicle weapons are",
        "-- config/vehicle_weapons.lua, from the same run.",
        "--",
        "-- To change a row, run the tool again on a newer dump:",
        "--     py tools/vehicle_models.py <path to vehicles.json>",
        "-- docs/devmenu.md says why the server needs it.",
        "--",
        "-- Source: vehicles.json, %d models (%s), %d armed, %d a jerry can fills, sha256 %s" % (
            len(rows), ', '.join('%d %s' % (trees[t], t) for t in sorted(trees)), armed, jerry,
            digest),
    ]
    lines = [
        "BR = BR or {}",
        "BR.Config = BR.Config or {}",
        "",
        "BR.Config.VehicleModels = {",
    ]
    for r in rows:
        name = ("'%s'," % r['name']).ljust(width)
        tree = "tree = '%s'" % r['tree']
        rest = []
        if 'reach' in r:
            rest.append('reach = %4.1f, below = %3.1f, front = %4.1f, rear = %4.1f'
                        % (r['reach'], r['below'], r['front'], r['rear']))
        if r.get('armed'):
            rest.append('armed = true')
        if r.get('jerryFills'):
            rest.append('jerryFills = true')
        if rest:
            tree = (tree + ',').ljust(len("tree = 'automobile',"))
            lines.append('    { name = %s hash = 0x%08X, %s %s },'
                         % (name, r['hash'], tree, ', '.join(rest)))
        else:
            lines.append('    { name = %s hash = 0x%08X, %s },' % (name, r['hash'], tree))
    lines.append('}')
    return with_checksum(header, '\n'.join(lines) + '\n')


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('dump', help="the game's vehicle data: DurtyFree's vehicles.json")
    ap.add_argument('--check', action='store_true', help='say whether the table is current')
    a = ap.parse_args(argv)

    with open(a.dump, 'rb') as f:
        raw = f.read()
    try:
        doc = json.loads(raw.decode('utf-8-sig'))
        rows = rows_of(doc)
        weapons = weapons_of(doc)
    except ValueError as e:
        print('refused, nothing written: %s' % e, file=sys.stderr)
        return 1
    digest = hashlib.sha256(raw).hexdigest()
    out = [(OUT, render(rows, digest), '%d models' % len(rows)),
           (WEAPONS_OUT, render_weapons(weapons, digest), '%d vehicle weapons' % len(weapons))]

    if a.check:
        stale = 0
        for path, text, what in out:
            try:
                with open(path, encoding='utf-8', newline='') as f:
                    have = f.read()
            except OSError:
                have = None
            if have == text:
                print('ok   %s is current: %s' % (path, what))
            else:
                print('%s is NOT what %s writes -- run it without --check' % (path, a.dump),
                      file=sys.stderr)
                stale += 1
        return 1 if stale else 0

    for path, text, what in out:
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        print('wrote %s: %s' % (path, what))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
