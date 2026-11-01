#!/usr/bin/env python3
"""Every base-game vehicle model (#426), written from the game's own vehicle data.

    py tools/vehicle_models.py <vehicles.json>            write the table
    py tools/vehicle_models.py <vehicles.json> --check    say whether it is current

WHAT IT READS. DurtyFree's dump of the game's vehicle data
(github.com/DurtyFree/gta-v-data-dumps, vehicles.json; game build 3717 when this
was first run): one object per vehicle model the game registers, with its type,
its bounding box and the vehicle weapons its data lists.

WHAT IT WRITES. resources/[fivem-royale]/br_lib/config/vehicle_models.lua, the
one table that says what the server knows about a model without asking a
client (BR.Config.VehicleModels): one row per model, in name order,
`{ name, hash, tree, reach, below, armed }`.

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
           Both are left out for a model the data has no bounding box for.
  * armed  true when the data lists a vehicle weapon on it -- a searchlight, a
           radar and a water cannon are not weapons. tools/check_vehicles.lua
           holds config/vehicles.lua's "Armed" set to exactly these.

Anything malformed is refused whole and nothing is written: a model with no
name, a name that is not a model word, a type this table has no tree for, a
hash that is not the name's, a name or a hash twice, or a bounding box that is
not six finite numbers.
"""

import argparse
import hashlib
import json
import math
import os
import re
import sys

OUT = os.path.join('resources', '[fivem-royale]', 'br_lib', 'config', 'vehicle_models.lua')
MODEL = re.compile(r'^[a-z0-9_]{1,64}$')

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


def tenth_up(v):
    """Meters, rounded UP to a tenth: a placement read off it clears the model."""
    return math.ceil(round(v * 10.0, 6)) / 10.0


def finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def rows_of(doc):
    """The rows, checked, in name order, or raises ValueError naming the first fault."""
    if not isinstance(doc, list) or not doc:
        raise ValueError('not a list of vehicle models')
    out, names, hashes = [], set(), set()
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
        weapons = v.get('Weapons') or []
        if not isinstance(weapons, list):
            raise ValueError('%s: weapons %r is not a list' % (name, weapons))
        if any(w not in NOT_WEAPONS for w in weapons):
            row['armed'] = True
        out.append(row)
    out.sort(key=lambda r: r['name'])
    return out


def render(rows, digest):
    width = max(len(r['name']) for r in rows) + 3
    trees = {}
    for r in rows:
        trees[r['tree']] = trees.get(r['tree'], 0) + 1
    armed = sum(1 for r in rows if r.get('armed'))
    lines = [
        "-- Every base-game vehicle model (#426): WRITTEN BY tools/vehicle_models.py",
        "-- FROM THE GAME'S OWN VEHICLE DATA, NOT EDITED. One row per model the game",
        "-- registers: its name and the game's hash for it; the sync tree",
        "-- CreateVehicleServerSetter has to build it as; how far it reaches across",
        "-- its width (`reach`) and below its origin (`below`), in meters rounded up;",
        "-- and `armed` where the data lists a vehicle weapon on it.",
        "--",
        "-- What reads it, and nothing else does: server/vehicles.lua's spawn, which",
        "-- builds a model the game has only as its own tree and puts a big one clear",
        "-- of the player; and tools/check_vehicles.lua, which re-derives every hash",
        "-- and holds config/vehicles.lua's \"Armed\" set to the `armed` rows. A model",
        "-- with no row -- an add-on -- is one the server takes the asker's word for.",
        "--",
        "-- To change a row, run the tool again on a newer dump:",
        "--     py tools/vehicle_models.py <path to vehicles.json>",
        "-- docs/devmenu.md says why the server needs it.",
        "--",
        "-- Source: vehicles.json, %d models (%s), %d armed, sha256 %s" % (
            len(rows), ', '.join('%d %s' % (trees[t], t) for t in sorted(trees)), armed, digest),
        "",
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
            rest.append('reach = %4.1f, below = %3.1f' % (r['reach'], r['below']))
        if r.get('armed'):
            rest.append('armed = true')
        if rest:
            tree = (tree + ',').ljust(len("tree = 'automobile',"))
            lines.append('    { name = %s hash = 0x%08X, %s %s },'
                         % (name, r['hash'], tree, ', '.join(rest)))
        else:
            lines.append('    { name = %s hash = 0x%08X, %s },' % (name, r['hash'], tree))
    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('dump', help="the game's vehicle data: DurtyFree's vehicles.json")
    ap.add_argument('--check', action='store_true', help='say whether the table is current')
    a = ap.parse_args(argv)

    with open(a.dump, 'rb') as f:
        raw = f.read()
    try:
        rows = rows_of(json.loads(raw.decode('utf-8-sig')))
    except ValueError as e:
        print('refused, nothing written: %s' % e, file=sys.stderr)
        return 1
    text = render(rows, hashlib.sha256(raw).hexdigest())

    if a.check:
        try:
            with open(OUT, encoding='utf-8', newline='') as f:
                have = f.read()
        except OSError:
            have = None
        if have == text:
            print('ok   %s is current: %d models' % (OUT, len(rows)))
            return 0
        print('%s is NOT what %s writes -- run it without --check' % (OUT, a.dump), file=sys.stderr)
        return 1

    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print('wrote %s: %d models' % (OUT, len(rows)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
