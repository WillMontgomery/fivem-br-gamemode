#!/usr/bin/env python3
"""Tests for tools/vehicle_models.py's one override: the plain Insurgent (#427).

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

THE FIXTURES ARE SMALL DUMPS BUILT HERE, in the shape DurtyFree's vehicles.json
has: nothing is downloaded, and each is build 3717's two Insurgents beside the
Weaponized Ignus with one fact changed. The tool itself runs in a temp
directory laid out like the repo, so a refusal that wrote anyway writes there
and fails a test, and never touches the real tables.
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


def model(name, weapons=(), skeleton=PLAIN):
    """One model, as the dump has it: the fields the tool reads."""
    return {
        'Name': name,
        'Hash': vm.joaat(name),
        'Type': 'CAR',
        'DimensionsMin': {'X': -1.42, 'Y': -3.24, 'Z': -0.92},
        'DimensionsMax': {'X': 1.41, 'Y': 3.0, 'Z': 1.71},
        'Weapons': list(weapons),
        'Bones': bones(skeleton),
    }


def dump(**plain):
    """Build 3717's two Insurgents, an unarmed car and the Weaponized Ignus --
    whose dump holds only a stub skeleton -- with the plain Insurgent's fields
    replaced by `plain`."""
    insurgent2 = model('insurgent2', (TURRET,), PLAIN)
    insurgent2.update(plain)
    return [
        model('adder'),
        model('ignus2', ('VEHICLE_WEAPON_IGNUS2_TURRET_MINI',), ('stub',)),
        model('insurgent', (TURRET,), PICKUP),
        insurgent2,
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
        self.assertIn(', 2 armed, sha256 ', table)
        rows = {line.split("'")[1]: line for line in table.splitlines()
                if line.startswith("    { name = '")}
        self.assertIn('armed = true', rows['insurgent'])
        self.assertNotIn('armed', rows['insurgent2'])
        self.assertIn('armed = true', rows['ignus2'])
        # THE TURRET IS STILL A VEHICLE WEAPON OF THE GAME'S: the Pick-Up fires
        # it, and a dev menu vehicle's gun is excused by that list.
        self.assertIn("'%s'," % TURRET, wrote[vm.WEAPONS_OUT])


if __name__ == '__main__':
    unittest.main()
