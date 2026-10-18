#!/usr/bin/env python3
"""Flick cameras (#419): the camera registry, written from the placement list.

    py tools/flick_cameras.py <flick_cameras.json>            write the registry
    py tools/flick_cameras.py <flick_cameras.json> --check    say whether it is current

WHAT IT WRITES. resources/[fivem-royale]/br_lib/config/flick_cameras.lua, the
one table both sides of the game read (BR.Config.Flick.cameras): one row per
camera the placement ymap stands, `{ id, x, y, z, h, region }`, in id order.
docs/flick.md says who reads it.

ONE SOURCE FOR BOTH FILES. The placement work (flick/place, outside this repo)
writes the ymap and flick_cameras.json from the same list, so the rows are
where the props stand. Nothing in this repo can read the ymap -- it lives in
the Season 2 asset drop -- so this file is the one place the two agree, and a
registry row is never edited by hand: fix the spot in the placement list and
run this again.

THE IDS ARE THE PLACEMENT'S, NEVER RENUMBERED HERE. A whole number from 1 to
9999, unique, never reused (flick/place/flick_ids.tsv remembers them), so a
match in flight, the dev tools and a later list all agree on what camera 117
is. Anything else is refused whole and nothing is written:

  * an id that is not a whole number in 1..9999, or one that repeats
  * a coordinate or heading that is not a finite number
  * a region that is not lower-case letters, digits and underscores

tools/check_boundary.lua (verify.sh's `map boundary`) then holds the written
rows to the play area, the count and the spacing.
"""

import argparse
import hashlib
import json
import math
import os
import re
import sys

OUT = os.path.join('resources', '[fivem-royale]', 'br_lib', 'config', 'flick_cameras.lua')
REGION = re.compile(r'^[a-z0-9_]{1,40}$')
NAME = re.compile(r'^[A-Za-z0-9_ .-]{1,60}$')


def finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def rows_of(doc):
    """The rows, checked, in id order, or raises ValueError naming the first fault."""
    cams = doc.get('cameras') if isinstance(doc, dict) else None
    if not isinstance(cams, list) or not cams:
        raise ValueError('no "cameras" list')
    out, seen = [], set()
    for i, c in enumerate(cams, 1):
        if not isinstance(c, dict):
            raise ValueError('camera %d is not an object' % i)
        cid = c.get('id')
        if not (isinstance(cid, int) and not isinstance(cid, bool) and 1 <= cid <= 9999):
            raise ValueError('camera %d: id %r is not a whole number in 1..9999' % (i, cid))
        if cid in seen:
            raise ValueError('camera %d: id %d repeats' % (i, cid))
        seen.add(cid)
        h = c.get('heading', c.get('h'))
        for key, v in (('x', c.get('x')), ('y', c.get('y')), ('z', c.get('z')), ('heading', h)):
            if not finite(v):
                raise ValueError('camera %d: %s %r is not a finite number' % (cid, key, v))
        region = c.get('region', '')
        if region and not REGION.match(str(region)):
            raise ValueError('camera %d: region %r' % (cid, region))
        name = c.get('name', '')
        if name and not NAME.match(str(name)):
            raise ValueError('camera %d: name %r' % (cid, name))
        out.append({'id': cid, 'x': float(c['x']), 'y': float(c['y']), 'z': float(c['z']),
                    'h': float(h) % 360.0, 'region': str(region), 'name': str(name)})
    out.sort(key=lambda r: r['id'])
    return out


def render(rows, digest, source):
    lines = [
        '-- Flick cameras (#419), Season 2: WRITTEN BY tools/flick_cameras.py FROM THE',
        '-- PLACEMENT LIST, NOT EDITED. One row per camera the placement ymap stands:',
        '-- the pole\'s foot on the ground (x, y, z), the GTA heading it stands at (h),',
        '-- and the nearest POI (region). The comment is the placement\'s display name,',
        '-- which renumbers when the set changes; the id never does.',
        '--',
        '-- To change a camera, fix the placement list and run the tool again:',
        '--     py tools/flick_cameras.py <path to flick_cameras.json>',
        '-- docs/flick.md says who reads these rows and why.',
        '--',
        '-- Source: %s, %d rows, sha256 %s' % (source, len(rows), digest),
        '',
        'BR = BR or {}',
        'BR.Config = BR.Config or {}',
        'BR.Config.Flick = BR.Config.Flick or {}',
        '',
        'BR.Config.Flick.cameras = {',
    ]
    for r in rows:
        row = ('    { id = %4d, x = %9.3f, y = %9.3f, z = %8.3f, h = %5.1f, region = %s },'
               % (r['id'], r['x'], r['y'], r['z'], r['h'], "'%s'" % r['region']))
        if r['name']:
            row += '  -- ' + r['name']
        lines.append(row)
    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv):
    ap = argparse.ArgumentParser(description='Write br_lib/config/flick_cameras.lua from flick_cameras.json.')
    ap.add_argument('json', help='the placement list, flick_cameras.json')
    ap.add_argument('--check', action='store_true', help='exit 1 if the registry is not what the list writes')
    ap.add_argument('--out', default=None, help='where to write (default: the repo registry)')
    a = ap.parse_args(argv)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = a.out or os.path.join(root, OUT)
    with open(a.json, 'rb') as fh:
        raw = fh.read()
    try:
        rows = rows_of(json.loads(raw.decode('utf-8')))
    except ValueError as e:
        print('flick_cameras: %s -- nothing written' % e, file=sys.stderr)
        return 1
    text = render(rows, hashlib.sha256(raw).hexdigest(), os.path.basename(a.json))

    if a.check:
        try:
            with open(out, 'r', encoding='utf-8', newline='') as fh:
                have = fh.read()
        except OSError:
            have = None
        if have != text:
            print('flick_cameras: %s is not what %s writes' % (out, a.json))
            return 1
        print('flick_cameras: %s is current (%d cameras)' % (out, len(rows)))
        return 0

    with open(out, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)
    print('flick_cameras: wrote %d cameras to %s' % (len(rows), out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
