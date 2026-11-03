#!/usr/bin/env python3
"""Tests for tools/vehicle_models.py's two rulings by name: the plain Insurgent
(#427) and the RC Bandito the jerry can leaves out (#217).

    py tools/test_vehicle_models.py         (Windows)
    python3 tools/test_vehicle_models.py    (Linux; tools/verify.sh runs it)

The game's vehicle data lists VEHICLE_WEAPON_TURRET_INSURGENT on two models:
`insurgent`, the Insurgent Pick-Up, which carries the turret, and `insurgent2`,
the plain Insurgent, whose model has no bone starting turret_ or weapon_ at
all. So the tool writes `insurgent2` unarmed, by name (its UNARMED), and checks
the reason on every run. tools/check_vehicles.lua holds config/vehicles.lua's
armed rows to exactly what the tool writes, so an override that outlived its
reason would be a gun nobody ruled on -- which is why a dump that shows the
plain Insurgent a turret_ or weapon_ bone, shows it no skeleton to look in, or
no longer gives it a weapon to override is refused whole, and nothing written.

THE JERRY CAN (#217) fills the tank of the game's own quads, dirt bikes and dune
buggies whole -- its quad-bike types and seven layouts -- and the tool writes
those rows `jerryFills`, with every sized row's `front` and `rear` beside them.
The RC Bandito is a remote-control toy in a buggy layout, and the owner's 26 do
not name it, so it is left out by name (JERRY_NOT) -- and a dump that no longer
puts it in the rule, or no longer has it, is refused whole the same way.

THE FIXTURES ARE SMALL DUMPS BUILT HERE, in the shape DurtyFree's vehicles.json
has: nothing is downloaded, and each is build 3717's two Insurgents beside the
Weaponized Ignus and the RC Bandito with one fact changed. The tool itself runs
in a temp directory laid out like the repo, so a refusal that wrote anyway
writes there and fails a test, and never touches the real tables.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
# The import would leave a __pycache__ in tools/, which nothing ignores.
sys.dont_write_bytecode = True
import vehicle_models as vm  # noqa: E402

TURRET = 'VEHICLE_WEAPON_TURRET_INSURGENT'
#: The bones that matter, as the dump names them on each model.
PICKUP = ('chassis', 'seat_dside_f', 'turret_1base', 'turret_1barrel', 'weapon_1a')
PLAIN = ('chassis', 'seat_dside_f', 'seat_pside_f', 'bodyshell')


def bones(names):
    return [{'BoneIndex': i, 'BoneId': i, 'BoneName': n} for i, n in enumerate(names)]


def model(name, weapons=(), skeleton=PLAIN, typ='CAR', layout='LAYOUT_VAN_ARMORED'):
    """One model, as the dump has it: the fields the tool reads. Every one is
    an Insurgent's size unless a test says otherwise."""
    return {
        'Name': name,
        'Hash': vm.joaat(name),
        'Type': typ,
        'LayoutId': layout,
        'DimensionsMin': {'X': -1.42, 'Y': -3.24, 'Z': -0.92},
        'DimensionsMax': {'X': 1.41, 'Y': 3.0, 'Z': 1.71},
        'Weapons': list(weapons),
        'Bones': bones(skeleton),
    }


def dump(**plain):
    """Build 3717's two Insurgents, an unarmed car, the Weaponized Ignus --
    whose dump holds only a stub skeleton -- and the RC Bandito in its buggy
    layout, with the plain Insurgent's fields replaced by `plain`."""
    insurgent2 = model('insurgent2', (TURRET,), PLAIN)
    insurgent2.update(plain)
    return [
        model('adder', layout='LAYOUT_LOW_RESTRICTED'),
        model('ignus2', ('VEHICLE_WEAPON_IGNUS2_TURRET_MINI',), ('stub',),
              layout='LAYOUT_LOW_IGNUS2'),
        model('insurgent', (TURRET,), PICKUP),
        insurgent2,
        model('rcbandito', layout='LAYOUT_LOW_DUNE'),
    ]


def armed(doc):
    return {r['name'] for r in vm.rows_of(doc) if r.get('armed')}


def run_tool(doc, *args):
    """vehicle_models.py's main over `doc`, in a temp copy of the repo's layout:
    (exit code, stderr, every file it wrote, by path, as text)."""
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.dirname(os.path.join(tmp, vm.OUT)))
        path = os.path.join(tmp, 'vehicles.json')
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(doc, f)
        err = io.StringIO()
        here = os.getcwd()
        os.chdir(tmp)
        try:
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                rc = vm.main([path, *args])
        finally:
            os.chdir(here)
        wrote = {}
        for rel in (vm.OUT, vm.WEAPONS_OUT):
            p = os.path.join(tmp, rel)
            if os.path.exists(p):
                with open(p, encoding='utf-8') as f:
                    wrote[rel] = f.read()
        return rc, err.getvalue(), wrote


class PlainInsurgent(unittest.TestCase):

    def test_the_pick_up_is_armed_and_the_plain_insurgent_is_not(self):
        self.assertEqual(armed(dump()), {'insurgent', 'ignus2'})

    def test_a_turret_or_weapon_bone_on_the_plain_insurgent_refuses_the_dump(self):
        # THE BRIEF'S CASE FIRST: a turret_ bone. Then a weapon_ one, and one
        # in capitals, which is the same bone to the engine.
        for bone in ('turret_1base', 'weapon_1a', 'Turret_1Barrel'):
            with self.subTest(bone=bone):
                with self.assertRaisesRegex(
                        ValueError, r'^insurgent2: the data now gives its model %s, '
                        r'so it may carry a gun after all -- its UNARMED override is stale$'
                        % bone.lower()):
                    vm.rows_of(dump(Bones=bones(PLAIN + (bone,))))

    def test_no_skeleton_to_look_in_refuses_the_dump(self):
        # A STUB IS WHAT THE DUMP HOLDS FOR A MODEL IT COULD NOT READ, and "no
        # turret_ bone" is true of a stub without saying anything.
        for skeleton in (bones(('stub',)), [], None, 'chassis'):
            with self.subTest(skeleton=skeleton):
                with self.assertRaisesRegex(ValueError, r'^insurgent2: the data shows no '
                                            r'skeleton for it'):
                    vm.rows_of(dump(Bones=skeleton))

    def test_an_override_with_nothing_to_override_refuses_the_dump(self):
        stale = r'^insurgent2: the data gives it no weapon to override, or does not have it'
        with self.subTest('no weapon'):
            with self.assertRaisesRegex(ValueError, stale):
                vm.rows_of(dump(Weapons=[]))
        with self.subTest('a searchlight, which is not a weapon'):
            with self.assertRaisesRegex(ValueError, stale):
                vm.rows_of(dump(Weapons=['VEHICLE_WEAPON_SEARCHLIGHT']))
        with self.subTest('no such model'):
            with self.assertRaisesRegex(ValueError, stale):
                vm.rows_of([m for m in dump() if m['Name'] != 'insurgent2'])

    def test_it_is_not_a_bone_rule(self):
        # THE WEAPONIZED IGNUS IS REALLY ARMED and its skeleton is a stub; a
        # model with a whole skeleton and no gun bone is armed by its weapons
        # too. The override is one model, by name.
        doc = dump()
        doc.append(model('nightshark', ('VEHICLE_WEAPON_NIGHTSHARK_MG',), PLAIN))
        self.assertEqual(armed(doc), {'insurgent', 'ignus2', 'nightshark'})

    def test_the_tool_refuses_and_writes_nothing(self):
        doc = dump(Bones=bones(PLAIN + ('turret_1base',)))
        for args in ((), ('--check',)):
            with self.subTest(args=args):
                rc, err, wrote = run_tool(doc, *args)
                self.assertEqual(rc, 1)
                self.assertTrue(err.startswith('refused, nothing written: insurgent2: '), err)
                self.assertEqual(wrote, {})

    def test_the_tool_writes_the_plain_insurgent_unarmed(self):
        rc, err, wrote = run_tool(dump())
        self.assertEqual((rc, err), (0, ''))
        table = wrote[vm.OUT]
        self.assertIn(', 2 armed, 0 a jerry can fills, sha256 ', table)
        rows = {line.split("'")[1]: line for line in table.splitlines()
                if line.startswith("    { name = '")}
        self.assertIn('armed = true', rows['insurgent'])
        self.assertNotIn('armed', rows['insurgent2'])
        self.assertIn('armed = true', rows['ignus2'])
        # THE TURRET IS STILL A VEHICLE WEAPON OF THE GAME'S: the Pick-Up fires
        # it, and a dev menu vehicle's gun is excused by that list.
        self.assertIn("'%s'," % TURRET, wrote[vm.WEAPONS_OUT])


def sized(name, ymin, ymax, typ='CAR', layout='LAYOUT_STANDARD'):
    """A model `ymin` to `ymax` meters along its length, an Insurgent across."""
    m = model(name, typ=typ, layout=layout)
    m['DimensionsMin'] = dict(m['DimensionsMin'], Y=ymin)
    m['DimensionsMax'] = dict(m['DimensionsMax'], Y=ymax)
    return m


def jerry(doc):
    return {r['name'] for r in vm.rows_of(doc) if r.get('jerryFills')}


#: The game's own grouping, one of each kind (build 3717's types and layouts),
#: beside the near misses that share a layout or a look with them.
GROUPS = [
    model('sanchez', typ='BIKE', layout='LAYOUT_BIKE_DIRT'),
    model('manchez2', typ='BIKE', layout='LAYOUT_BIKE_MANCHEZ2'),
    model('blazer', typ='QUADBIKE', layout='LAYOUT_BIKE_QUAD'),
    model('blazer5', typ='AMPHIBIOUS_QUADBIKE', layout='LAYOUT_BIKE_QUAD_AQUA'),
    model('chimera', typ='QUADBIKE', layout='LAYOUT_BIKE_FREEWAY_CHIMERA'),
    model('stryder', typ='QUADBIKE', layout='LAYOUT_BIKE_SPORT'),
    model('dune', layout='LAYOUT_LOW_DUNE'),
    model('dune3', layout='LAYOUT_LOW_DUNE3'),
    model('bfinjection', layout='LAYOUT_LOW_BFINJECTION'),
    model('outlaw', layout='LAYOUT_STD_OUTLAW'),
    model('vagrant', layout='LAYOUT_LOW_VAGRANT'),
    # THE NEAR MISSES: a road bike in the Chimera's layout and one in the
    # Stryder's, a trophy truck, a buggy-shaped car in a layout of its own.
    model('ratbike', typ='BIKE', layout='LAYOUT_BIKE_FREEWAY_CHIMERA'),
    model('akuma', typ='BIKE', layout='LAYOUT_BIKE_SPORT'),
    model('trophytruck', layout='LAYOUT_STD_TROPHY'),
    model('squaddie', layout='LAYOUT_SQUADDIE'),
]


class JerryCan(unittest.TestCase):

    def test_the_rule_is_the_games_grouping_less_the_rc_bandito(self):
        self.assertEqual(jerry(dump() + GROUPS), {
            'sanchez', 'manchez2', 'blazer', 'blazer5', 'chimera', 'stryder',
            'dune', 'dune3', 'bfinjection', 'outlaw', 'vagrant'})

    def test_a_quad_type_is_enough_and_a_layout_alone_is_not(self):
        # THE TRIKES ARE TYPED AS QUADS and share their layouts with road bikes:
        # the type takes the Stryder and the Chimera, and the same layouts on a
        # BIKE take nothing.
        rows = {r['name']: r for r in vm.rows_of(dump() + GROUPS)}
        self.assertTrue(rows['stryder'].get('jerryFills'))
        self.assertTrue(rows['chimera'].get('jerryFills'))
        self.assertNotIn('jerryFills', rows['akuma'])
        self.assertNotIn('jerryFills', rows['ratbike'])
        # TRUE OR ABSENT, like `armed`: never written false.
        self.assertNotIn('jerryFills', rows['adder'])
        self.assertNotIn('jerryFills', rows['rcbandito'])

    def test_a_missing_layout_is_no_layout(self):
        # A model the dump gives no LayoutId is judged by its type alone.
        quad = model('verus', typ='QUADBIKE')
        del quad['LayoutId']
        car = model('bifta')
        del car['LayoutId']
        self.assertEqual(jerry(dump() + [quad, car]), {'verus'})

    def test_front_and_rear_are_the_box_along_its_length_rounded_up(self):
        rows = {r['name']: r for r in vm.rows_of(dump() + [
            sized('sanchez', -1.076763, 1.1731756, 'BIKE', 'LAYOUT_BIKE_DIRT'),
            sized('ahead', 0.25, 2.0),        # a box wholly ahead of its origin
            sized('behind', -2.0, -0.25),     # and one wholly behind it
            sized('exact', -3.0, 3.0),        # a tenth exactly is not rounded past
        ])}
        self.assertEqual((rows['sanchez']['front'], rows['sanchez']['rear']), (1.2, 1.1))
        self.assertEqual((rows['ahead']['front'], rows['ahead']['rear']), (2.0, 0.0))
        self.assertEqual((rows['behind']['front'], rows['behind']['rear']), (0.0, 2.0))
        self.assertEqual((rows['exact']['front'], rows['exact']['rear']), (3.0, 3.0))
        # THE EXISTING TWO DO NOT MOVE: the Insurgent's reach and below.
        self.assertEqual((rows['insurgent']['reach'], rows['insurgent']['below']), (1.5, 1.0))
        self.assertEqual((rows['insurgent']['front'], rows['insurgent']['rear']), (3.0, 3.3))

    def test_a_model_with_no_box_has_none_of_the_four_sizes(self):
        stub = model('s95', layout='LAYOUT_LOW')
        del stub['DimensionsMin'], stub['DimensionsMax']
        row = {r['name']: r for r in vm.rows_of(dump() + [stub])}['s95']
        for k in ('reach', 'below', 'front', 'rear'):
            self.assertNotIn(k, row)

    def test_a_stale_exclusion_refuses_the_dump(self):
        stale = (r'^rcbandito: the data puts it in no quad type, dirt-bike layout or '
                 r'dune-buggy layout, or does not have it -- its JERRY_NOT exclusion is stale$')
        moved = [m for m in dump() if m['Name'] != 'rcbandito']
        with self.subTest('another layout'):
            with self.assertRaisesRegex(ValueError, stale):
                vm.rows_of(moved + [model('rcbandito', layout='LAYOUT_LOW')])
        with self.subTest('no layout at all'):
            gone = model('rcbandito')
            del gone['LayoutId']
            with self.assertRaisesRegex(ValueError, stale):
                vm.rows_of(moved + [gone])
        with self.subTest('no such model'):
            with self.assertRaisesRegex(ValueError, stale):
                vm.rows_of(moved)
        with self.subTest('still in the rule by its type, it still counts'):
            self.assertEqual(jerry(moved + [model('rcbandito', typ='QUADBIKE', layout='LAYOUT_LOW')]),
                             set())

    def test_a_layout_that_is_not_a_name_refuses_the_dump(self):
        doc = dump()
        doc[0]['LayoutId'] = 7
        with self.assertRaisesRegex(ValueError, r'^adder: layout 7 is not a name$'):
            vm.rows_of(doc)

    def test_the_tool_refuses_a_stale_exclusion_and_writes_nothing(self):
        doc = [m for m in dump() if m['Name'] != 'rcbandito']
        doc.append(model('rcbandito', layout='LAYOUT_LOW'))
        for args in ((), ('--check',)):
            with self.subTest(args=args):
                rc, err, wrote = run_tool(doc, *args)
                self.assertEqual(rc, 1)
                self.assertTrue(err.startswith('refused, nothing written: rcbandito: '), err)
                self.assertEqual(wrote, {})

    def test_the_tool_writes_the_three_fields(self):
        quad = sized('blazer5', -1.2468296, 1.3296019, 'AMPHIBIOUS_QUADBIKE',
                     'LAYOUT_BIKE_QUAD_AQUA')
        quad['Weapons'] = ['VEHICLE_WEAPON_TURRET_BLAZER']
        bike = sized('sanchez', -1.076763, 1.1731756, 'BIKE', 'LAYOUT_BIKE_DIRT')
        rc, err, wrote = run_tool(dump() + [quad, bike])
        self.assertEqual((rc, err), (0, ''))
        table = wrote[vm.OUT]
        self.assertIn(', 3 armed, 2 a jerry can fills, sha256 ', table)
        rows = {line.split("'")[1]: line for line in table.splitlines()
                if line.startswith("    { name = '")}
        # THE ORDER THE CONTRACT PINS: the four sizes, then `armed`, then
        # `jerryFills`, each written `%4.1f` but `below`.
        self.assertTrue(rows['sanchez'].endswith(
            "reach =  1.5, below = 1.0, front =  1.2, rear =  1.1, jerryFills = true },"),
            rows['sanchez'])
        self.assertTrue(rows['blazer5'].endswith(
            "front =  1.4, rear =  1.3, armed = true, jerryFills = true },"), rows['blazer5'])
        self.assertTrue(rows['insurgent'].endswith(
            "reach =  1.5, below = 1.0, front =  3.0, rear =  3.3, armed = true },"),
            rows['insurgent'])
        self.assertNotIn('jerryFills', rows['rcbandito'])
        self.assertNotIn('jerryFills', rows['adder'])


if __name__ == '__main__':
    unittest.main()
