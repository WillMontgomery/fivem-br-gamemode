#!/usr/bin/env python3
"""The data center's main gate (#420): the gate registry, written from the map's door table.

    py tools/dcgate_parts.py <brdc_site_doors.json> <kit_gate_doors.json>              write it
    py tools/dcgate_parts.py <brdc_site_doors.json> <kit_gate_doors.json> --check      is it current?
    ... --locks <br_datacenter client.lua>       also hold the pack's DOOR_LOCKS to the same rows

WHAT IT WRITES. resources/[fivem-royale]/br_lib/config/dcgate_parts.lua, the one
table both sides of the game read (BR.Config.DcGate.parts): the main gate's three
lanes, each with its four bi-fold leads, four followers and its crash arm (the 24
leaves and 3 arms the gamemode registers, locks and opens), the lane's box (the
ground a closing gate waits on), and the six lane readers. docs/dcgate.md says
who reads it.

TWO SOURCES, BOTH THE MAP'S. The site works' door table (doors/brdc_site_doors.json
in the br_datacenter pack: every placed door object's id, model, origin and
heading, and every reader) says WHERE each part stands; the gate kit's door spec
(build/staging/kits/gate/kit_gate_doors.json: pivots, axes, senses, attach
offsets, the arm's raise) says HOW each one moves. Nothing in this repo can read
the ymaps, so this file is where the two agree, and a row is never edited by hand:
fix the map and run this again.

REFUSED WHOLE, NOTHING WRITTEN, for anything it cannot trust:

  * a lane that is not exactly lanes 1..3, each with an outer and an inner gate
    of lead_l, lead_r, follow_l and follow_r, one outer arm, a reader_in and a
    reader_out
  * a part whose model is not the kit's archetype for its role
  * a coordinate or heading that is not a finite number
  * a follower not attached to its own gate's lead, whose offset is not the
    kit's, whose heading is not its lead's, or that does not stand where its
    lead's knuckle puts it (2 cm)
  * a lead's open sense, a follower's counter-rotation or the arm's raise the kit
    does not spell as this file reads it -- or a pair whose counter-rotation is
    not -2 times its lead's turn (the bi-fold's whole geometry)
  * with --locks: a part the pack's DOOR_LOCKS lists with another model or more
    than 1 cm from the door table
"""

import argparse
import hashlib
import json
import math
import os
import re
import sys

OUT = os.path.join('resources', '[fivem-royale]', 'br_lib', 'config', 'dcgate_parts.lua')
LANES = (1, 2, 3)
ROLES = ('lead_l', 'lead_r', 'follow_l', 'follow_r')
GATES = ('outer', 'inner')
#: How far past the arm's pivot line the lane's box reaches, along the lane: the
#: arm is one beam across it (both beams on one bone, rotating about the lane's
#: own axis), so a quarter meter covers the beam and its catch.
ARM_DEPTH_M = 0.25
ID = re.compile(r'^[a-z0-9_.]{1,60}$')
MODEL = re.compile(r'^[a-z0-9_]{1,40}$')


class Refused(ValueError):
    pass


def finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def vec3(v, what):
    if not (isinstance(v, list) and len(v) == 3 and all(finite(c) for c in v)):
        raise Refused('%s: %r is not three finite numbers' % (what, v))
    return [float(c) for c in v]


def heading_of(d, what):
    h = d.get('heading')
    if not finite(h):
        raise Refused('%s: heading %r is not a finite number' % (what, h))
    return float(h) % 360.0


def local_to_world(h, x, y):
    """A model-local (x, y) offset turned into the world by GTA heading h (degrees,
    counter-clockwise from above, about +z)."""
    r = math.radians(h)
    return (x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r))


def sense_of(text, word, what):
    """'+1' or '-1' from a kit sentence such as 'rotate about local +z by +theta'."""
    m = re.search(r'by\s*([+-])\s*%s' % word, str(text or ''))
    if not m:
        raise Refused('%s: the kit says %r, not "by +%s" or "by -%s"' % (what, text, word, word))
    return 1 if m.group(1) == '+' else -1


def kit_of(doc):
    """What the kit says about how each part moves."""
    arch = doc.get('archetypes') if isinstance(doc, dict) else None
    if not isinstance(arch, dict):
        raise Refused('the kit has no "archetypes"')

    def a(name):
        v = arch.get(name)
        if not isinstance(v, dict):
            raise Refused('the kit has no archetype %s' % name)
        return v

    out = {'lead': {}, 'follow': {}}
    lead_l = a('brdc_bifold_lead_l')
    mid = lead_l.get('leaf_mid_height_above_grade')
    if not finite(mid):
        raise Refused('the kit gives no leaf_mid_height_above_grade for brdc_bifold_lead_l')
    out['leaf_mid_height'] = float(mid)
    knuckles = []
    for side in ('l', 'r'):
        lead = a('brdc_bifold_lead_' + side)
        follow = a('brdc_bifold_follow_' + side)
        lsense = sense_of(lead.get('open'), 'theta', 'brdc_bifold_lead_' + side + ' open')
        rot = str(follow.get('attach_rotation', ''))
        m = re.match(r'^\(\s*0\s*,\s*0\s*,\s*([+-])\s*2\s*\*\s*theta\s*\)$', rot)
        if not m:
            raise Refused('brdc_bifold_follow_%s: attach_rotation %r is not "(0, 0, +-2*theta)"' % (side, rot))
        fturn = 2 if m.group(1) == '+' else -2
        # THE BI-FOLD: the follower turns twice its lead's turn, the other way, so
        # it stays parallel to the gate line as the knuckle swings out.
        if fturn / lsense != -2:
            raise Refused('the kit\'s %s pair does not counter-rotate: the lead turns %+d theta, the '
                          'follower %+d theta' % (side, lsense, fturn))
        off = vec3(follow.get('attach_offset'), 'brdc_bifold_follow_%s attach_offset' % side)
        if follow.get('attach_to') != 'brdc_bifold_lead_%s bone 0' % side:
            raise Refused('brdc_bifold_follow_%s is attached to %r, not its lead\'s bone 0'
                          % (side, follow.get('attach_to')))
        knuckle = lead.get('knuckle_local')
        if knuckle is not None and vec3(knuckle, 'brdc_bifold_lead_%s knuckle_local' % side) != off:
            raise Refused('brdc_bifold_lead_%s: the knuckle %r is not the follower\'s offset %r'
                          % (side, knuckle, off))
        out['lead'][side] = {'model': 'brdc_bifold_lead_' + side, 'sense': lsense}
        out['follow'][side] = {'model': 'brdc_bifold_follow_' + side, 'offset': off, 'turn': -2}
        knuckles.append(math.hypot(off[0], off[1]))
    out['knuckle_m'] = max(knuckles)
    arm = a('brdc_croparm_arm')
    raise_text = str(arm.get('raise_motion', ''))
    m = re.search(r'about local \+([xyz]) by ([+-])raise', raise_text)
    if not m:
        raise Refused('brdc_croparm_arm: raise_motion %r is not "rotate about local +<axis> by +-raise"'
                      % raise_text)
    out['arm'] = {'model': 'brdc_croparm_arm', 'axis': m.group(1), 'sense': 1 if m.group(2) == '+' else -1}
    cab = a('brdc_croparm_cab_r')
    pivot = vec3(cab.get('arm_pivot_offset'), 'brdc_croparm_cab_r arm_pivot_offset')
    out['arm_pivot_height'] = pivot[2]
    return out


def doors_of(doc, kit):
    """The lanes and readers, checked, or raises Refused naming the first fault."""
    doors = doc.get('doors') if isinstance(doc, dict) else None
    readers = doc.get('readers') if isinstance(doc, dict) else None
    if not isinstance(doors, list) or not isinstance(readers, list):
        raise Refused('no "doors" and "readers" lists')
    by_id = {}
    for i, d in enumerate(doors, 1):
        if not isinstance(d, dict) or not isinstance(d.get('id'), str):
            raise Refused('door %d has no id' % i)
        by_id[d['id']] = d

    def part(pid, model, what):
        d = by_id.get(pid)
        if d is None:
            raise Refused('the door table has no %s' % pid)
        if d.get('model') != model:
            raise Refused('%s is model %r, not the kit\'s %s for a %s' % (pid, d.get('model'), model, what))
        if not ID.match(pid) or not MODEL.match(model):
            raise Refused('%s: an id or model this file cannot write' % pid)
        p = vec3(d.get('position'), pid + ' position')
        return {'id': pid, 'model': model, 'x': p[0], 'y': p[1], 'z': p[2], 'h': heading_of(d, pid)}

    lanes = []
    for n in LANES:
        lane = {'lane': n, 'leads': [], 'follows': [], 'gates': {}}
        for gate in GATES:
            g = {}
            for side in ('l', 'r'):
                lead = part('gate.lane%d.%s.lead_%s' % (n, gate, side), kit['lead'][side]['model'], 'lead')
                lead['sense'] = kit['lead'][side]['sense']
                lane['leads'].append(lead)
                fk = kit['follow'][side]
                fid = 'gate.lane%d.%s.follow_%s' % (n, gate, side)
                follow = part(fid, fk['model'], 'follower')
                raw = by_id[fid]
                if raw.get('attach_to') != lead['id']:
                    raise Refused('%s is attached to %r, not %s' % (fid, raw.get('attach_to'), lead['id']))
                if raw.get('attach_offset') is not None and vec3(raw['attach_offset'], fid) != fk['offset']:
                    raise Refused('%s: attach_offset %r is not the kit\'s %r' % (fid, raw['attach_offset'], fk['offset']))
                if abs(((follow['h'] - lead['h'] + 180.0) % 360.0) - 180.0) > 0.01:
                    raise Refused('%s stands at heading %.2f, its lead at %.2f' % (fid, follow['h'], lead['h']))
                wx, wy = local_to_world(lead['h'], fk['offset'][0], fk['offset'][1])
                miss = math.hypot(lead['x'] + wx - follow['x'], lead['y'] + wy - follow['y'])
                miss = max(miss, abs(lead['z'] + fk['offset'][2] - follow['z']))
                if miss > 0.02:
                    raise Refused('%s stands %.3f m from where %s\'s knuckle puts it' % (fid, miss, lead['id']))
                follow['lead'] = len(lane['leads'])
                follow['ox'], follow['oy'], follow['oz'] = fk['offset']
                follow['turn'] = fk['turn']
                lane['follows'].append(follow)
                g[side] = lead
            lane['gates'][gate] = g
        arm = part('gate.lane%d.outer_arm.arm' % n, kit['arm']['model'], 'crash arm')
        arm['axis'], arm['sense'] = kit['arm']['axis'], kit['arm']['sense']
        lane['arm'] = arm
        lanes.append(lane)

    rows = []
    seen = set()
    for i, r in enumerate(readers, 1):
        rid = r.get('id') if isinstance(r, dict) else None
        m = re.match(r'^gate\.lane(\d)\.reader_(in|out)$', str(rid))
        if not m:
            continue
        n = int(m.group(1))
        if n not in LANES or rid in seen:
            raise Refused('reader %s: no such lane, or a second one' % rid)
        seen.add(rid)
        p = vec3(r.get('position'), rid + ' position')
        rows.append({'id': rid, 'lane': n, 'side': m.group(2), 'x': p[0], 'y': p[1], 'z': p[2],
                     'h': heading_of(r, rid)})
    for n in LANES:
        for side in ('in', 'out'):
            if 'gate.lane%d.reader_%s' % (n, side) not in seen:
                raise Refused('the door table has no gate.lane%d.reader_%s' % (n, side))
    rows.sort(key=lambda r: (r['lane'], 0 if r['side'] == 'in' else 1))
    return lanes, rows


def box_of(lane, kit):
    """The lane's box: the ground a closing gate waits on. Along the lane from the
    crash arm's beam to the inner gate's fold, across it from post to post, and
    from the lowest grade under the parts to the highest."""
    outer, inner = lane['gates']['outer'], lane['gates']['inner']
    ox = (outer['l']['x'] + outer['r']['x']) / 2.0
    oy = (outer['l']['y'] + outer['r']['y']) / 2.0
    ix = (inner['l']['x'] + inner['r']['x']) / 2.0
    iy = (inner['l']['y'] + inner['r']['y']) / 2.0
    run = math.hypot(ix - ox, iy - oy)
    if run < 5.0:
        raise Refused('lane %d: its gates are %.2f m apart' % (lane['lane'], run))
    ux, uy = (ix - ox) / run, (iy - oy) / run

    # Each gate folds toward its leads' local +y (a +theta turn of a leaf along +x
    # and a -theta turn of one along -x both swing it there): the outer one out
    # of the lane toward the arm, the inner one into the campus. Both must, or
    # the box is on the wrong side of a gate.
    for gate, want in (('outer', -1.0), ('inner', 1.0)):
        for side in ('l', 'r'):
            lead = lane['gates'][gate][side]
            fx, fy = local_to_world(lead['h'], 0.0, 1.0)
            if (fx * ux + fy * uy) * want < 0.5:
                raise Refused('lane %d: %s does not fold %s' % (
                    lane['lane'], lead['id'], 'into the campus' if want > 0 else 'out toward the arm'))

    def along(x, y):
        return (x - ox) * ux + (y - oy) * uy

    arm = lane['arm']
    lo = min(along(arm['x'], arm['y']) - ARM_DEPTH_M, -kit['knuckle_m'])
    hi = along(ix, iy) + kit['knuckle_m']
    half_w = math.hypot(outer['l']['x'] - outer['r']['x'], outer['l']['y'] - outer['r']['y']) / 2.0
    grades = [l['z'] - kit['leaf_mid_height'] for l in lane['leads']]
    grades.append(arm['z'] - kit['arm_pivot_height'])
    mid = (lo + hi) / 2.0
    return {'x': ox + ux * mid, 'y': oy + uy * mid, 'ux': ux, 'uy': uy,
            'halfLength': (hi - lo) / 2.0, 'halfWidth': half_w,
            'zLow': min(grades), 'zHigh': max(grades)}


def locks_of(text):
    """The pack's DOOR_LOCKS rows: id -> (model, x, y, z)."""
    out = {}
    for m in re.finditer(r"\{\s*'([^']+)'\s*,\s*`([^`]+)`\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\}", text):
        out[m.group(1)] = (m.group(2), float(m.group(3)), float(m.group(4)), float(m.group(5)))
    return out


def held_by_pack(lanes, locks):
    """How many of the parts the pack still locks; raises on one it lists differently."""
    held = 0
    for lane in lanes:
        for p in lane['leads'] + lane['follows'] + [lane['arm']]:
            row = locks.get(p['id'])
            if row is None:
                continue
            held += 1
            miss = math.sqrt((row[1] - p['x']) ** 2 + (row[2] - p['y']) ** 2 + (row[3] - p['z']) ** 2)
            if row[0] != p['model'] or miss > 0.01:
                raise Refused('the pack locks %s as %s %.3f m away from the door table\'s' % (p['id'], row[0], miss))
    return held


def num(v):
    s = ('%.4f' % v).rstrip('0')
    return s + '0' if s.endswith('.') else s


def render(lanes, readers, kit, sources):
    boxes = [box_of(l, kit) for l in lanes]
    pts = []
    for lane in lanes:
        pts += [(p['x'], p['y'], p['z']) for p in lane['leads'] + lane['follows'] + [lane['arm']]]
    pts += [(r['x'], r['y'], r['z']) for r in readers]
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    cz = sum(p[2] for p in pts) / len(pts)
    radius = max(math.hypot(p[0] - cx, p[1] - cy) for p in pts)

    def place(p):
        return 'x = %s, y = %s, z = %s, h = %s' % (num(p['x']), num(p['y']), num(p['z']), num(p['h']))

    lines = [
        '-- The data center\'s main gate (#420), Season 2: WRITTEN BY tools/dcgate_parts.py',
        '-- FROM THE MAP\'S DOOR TABLE AND THE GATE KIT, NOT EDITED. The three lanes\' 24',
        '-- bi-fold leaves and 3 crash arms the gamemode registers, locks and opens, each',
        '-- lane\'s box (the ground a closing gate waits on) and the six lane readers.',
        '--',
        '--   leads    x, y, z, h: the placed origin (the hinge axis, leaf mid-height) and',
        '--            heading; sense: +1 opens by +theta about local +z, -1 by -theta',
        '--   follows  rides its lead (`lead`, an index into leads) at the knuckle',
        '--            (ox, oy, oz), turned `turn` times its lead\'s turn: the bi-fold',
        '--   arm      turns about local +`axis` by `sense` times the raise',
        '--   box      a center, the lane\'s direction (ux, uy) from the outer gate to the',
        '--            inner one, half its length and width, and the grade under it',
        '--',
        '-- To change a part, fix the map and run the tool again:',
        '--     py tools/dcgate_parts.py <brdc_site_doors.json> <kit_gate_doors.json>',
        '-- docs/dcgate.md says who reads these rows and why.',
        '--',
    ]
    for name, digest in sources:
        lines.append('-- Source: %s, sha256 %s' % (name, digest))
    lines += [
        '',
        'BR = BR or {}',
        'BR.Config = BR.Config or {}',
        'BR.Config.DcGate = BR.Config.DcGate or {}',
        '',
        'BR.Config.DcGate.parts = {',
        '    center = { x = %s, y = %s, z = %s }, radius = %s,' % (num(cx), num(cy), num(cz), num(radius)),
        '    lanes = {',
    ]
    for lane, box in zip(lanes, boxes):
        lines.append('        {')
        lines.append('            lane = %d,' % lane['lane'])
        lines.append('            box = { x = %s, y = %s, ux = %s, uy = %s, halfLength = %s, halfWidth = %s, '
                     'zLow = %s, zHigh = %s },' % (num(box['x']), num(box['y']), num(box['ux']), num(box['uy']),
                                                   num(box['halfLength']), num(box['halfWidth']),
                                                   num(box['zLow']), num(box['zHigh'])))
        lines.append('            leads = {')
        for p in lane['leads']:
            lines.append("                { id = '%s', model = '%s', %s, sense = %d }," % (
                p['id'], p['model'], place(p), p['sense']))
        lines.append('            },')
        lines.append('            follows = {')
        for p in lane['follows']:
            lines.append("                { id = '%s', model = '%s', %s, lead = %d, ox = %s, oy = %s, oz = %s, "
                         "turn = %d }," % (p['id'], p['model'], place(p), p['lead'], num(p['ox']), num(p['oy']),
                                           num(p['oz']), p['turn']))
        lines.append('            },')
        a = lane['arm']
        lines.append("            arm = { id = '%s', model = '%s', %s, axis = '%s', sense = %d }," % (
            a['id'], a['model'], place(a), a['axis'], a['sense']))
        lines.append('        },')
    lines.append('    },')
    lines.append('    readers = {')
    for r in readers:
        lines.append("        { id = '%s', lane = %d, side = '%s', %s }," % (r['id'], r['lane'], r['side'], place(r)))
    lines.append('    },')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv):
    ap = argparse.ArgumentParser(description='Write br_lib/config/dcgate_parts.lua from the map\'s door table.')
    ap.add_argument('doors', help='the site works\' door table, brdc_site_doors.json')
    ap.add_argument('kit', help='the gate kit\'s door spec, kit_gate_doors.json')
    ap.add_argument('--check', action='store_true', help='exit 1 if the registry is not what the sources write')
    ap.add_argument('--locks', default=None, help='the br_datacenter pack\'s client.lua, to hold DOOR_LOCKS to the rows')
    ap.add_argument('--out', default=None, help='where to write (default: the repo registry)')
    a = ap.parse_args(argv)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = a.out or os.path.join(root, OUT)
    raws = []
    for path in (a.doors, a.kit):
        with open(path, 'rb') as fh:
            raws.append(fh.read())
    try:
        kit = kit_of(json.loads(raws[1].decode('utf-8')))
        lanes, readers = doors_of(json.loads(raws[0].decode('utf-8')), kit)
        held = None
        if a.locks:
            with open(a.locks, 'r', encoding='utf-8') as fh:
                held = held_by_pack(lanes, locks_of(fh.read()))
        text = render(lanes, readers, kit, [(os.path.basename(a.doors), hashlib.sha256(raws[0]).hexdigest()),
                                            (os.path.basename(a.kit), hashlib.sha256(raws[1]).hexdigest())])
    except Refused as e:
        print('dcgate_parts: %s -- nothing written' % e, file=sys.stderr)
        return 1

    parts = sum(len(l['leads']) + len(l['follows']) + 1 for l in lanes)
    if held is not None:
        if held:
            print('dcgate_parts: the pack still locks %d of these %d parts: drop them from its DOOR_LOCKS '
                  'in the same publish (#420)' % (held, parts))
        else:
            print('dcgate_parts: the pack locks none of these %d parts' % parts)

    if a.check:
        try:
            with open(out, 'r', encoding='utf-8', newline='') as fh:
                have = fh.read()
        except OSError:
            have = None
        if have != text:
            print('dcgate_parts: %s is not what the sources write' % out)
            return 1
        print('dcgate_parts: %s is current (%d lanes, %d parts, %d readers)' % (out, len(lanes), parts, len(readers)))
        return 0

    with open(out, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)
    print('dcgate_parts: wrote %d lanes, %d parts and %d readers to %s' % (len(lanes), parts, len(readers), out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
