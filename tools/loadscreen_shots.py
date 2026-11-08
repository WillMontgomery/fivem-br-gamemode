#!/usr/bin/env python3
"""The loading screen's carousel stills, made from whatever images the owner hands over (#423).

    py tools/loadscreen_shots.py <image or folder>...    replace the whole set, in this order
    py tools/loadscreen_shots.py --list                  show what is in the set now

Each image becomes resources/[fivem-royale]/br_loadscreen/shots/NN.webp:
1920x1080, cropped to fill like the page's `background-size: cover`, in sRGB,
with no metadata, and at the highest quality that fits MAX_BYTES. The page's
list of stills (between `shots:begin` and `shots:end` in index.html) is
rewritten to match, and stills left over from the last set are removed.

THE BYTES ARE ON THE CRITICAL PATH. A loadscreen resource is downloaded before
its page can show, so every still is time a first join spends on a black
screen. Hence one size for every monitor (the photo sits under a grade, a
hatch and a push-in, where 1080p upscaled to 4K reads fine) and a per-still
budget the quality search has to fit, rather than a fixed quality.

WEBP, NOT JPEG: about a third smaller at the same look, and CEF has decoded it
since long before Chrome 103. A CSS background is decoded from its bytes,
whatever type the file is served as.

THE ORDER IS THE OWNER'S. Arguments are taken in the order given and a folder
in name order, and the first still is the one the reel opens on.

Needs Pillow (`py -m pip install Pillow`); nothing else in this repository does.
"""
import argparse
import io
import re
import sys
from pathlib import Path

try:
    from PIL import Image, ImageCms, ImageOps
except ImportError:
    sys.exit('loadscreen_shots: needs Pillow -- py -m pip install Pillow')

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / 'resources' / '[fivem-royale]' / 'br_loadscreen'
SHOTS = RES / 'shots'
PAGE = RES / 'index.html'

SIZE = (1920, 1080)
MAX_BYTES = 300 * 1024
Q_TOP, Q_FLOOR = 90, 50
SOURCES = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff'}

# What the tool owns in shots/: its own numbered output and nothing else, so a
# file somebody put there by hand is never deleted by a rerun.
OURS = re.compile(r'^\d{2}\.webp$')
MARKS = re.compile(r'(/\* shots:begin \*/)(.*?)([ \t]*/\* shots:end \*/)', re.S)

# The page's own background, under any transparency a source carries: a
# screenshot has none, but a PNG export can, and black would not match.
BACKDROP = (6, 8, 14)


def natural(p):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)', p.name)]


def gather(args):
    """The sources, in the order given; a folder's images in name order."""
    found = []
    for a in args:
        p = Path(a)
        if p.is_dir():
            found += sorted((f for f in p.iterdir() if f.suffix.lower() in SOURCES), key=natural)
        elif p.is_file() and p.suffix.lower() in SOURCES:
            found.append(p)
        else:
            sys.exit(f'loadscreen_shots: not an image or a folder of them: {a}')
    if not found:
        sys.exit('loadscreen_shots: no images found')
    return found


def srgb(im):
    """sRGB without alpha. CEF draws an untagged image as sRGB, so a wide-gamut
    source (a Display P3 PNG, say) is converted here rather than left to look
    washed out in game."""
    icc = im.info.get('icc_profile')
    im = ImageOps.exif_transpose(im)
    alpha = im.mode in ('RGBA', 'LA', 'PA') or (im.mode == 'P' and 'transparency' in im.info)
    mode = 'RGBA' if alpha else 'RGB'
    im = im.convert(mode)
    if icc:
        try:
            src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            im = ImageCms.profileToProfile(im, src, ImageCms.createProfile('sRGB'), outputMode=mode)
        except (OSError, ImageCms.PyCMSError):
            pass   # an unreadable profile: take the pixels as sRGB, as CEF would
    if alpha:
        flat = Image.new('RGB', im.size, BACKDROP)
        flat.paste(im, mask=im.getchannel('A'))
        im = flat
    return im


def encode(im):
    """The highest quality whose file fits MAX_BYTES; the floor if none does."""
    def at(q):
        buf = io.BytesIO()
        im.save(buf, 'WEBP', quality=q, method=6)
        return buf.getvalue()

    lo, hi, best = Q_FLOOR, Q_TOP, None
    while lo <= hi:
        mid = (lo + hi) // 2
        data = at(mid)
        if len(data) <= MAX_BYTES:
            best, lo = (mid, data), mid + 1
        else:
            hi = mid - 1
    return best or (Q_FLOOR, at(Q_FLOOR))


def rewrite_page(names):
    html = PAGE.read_text(encoding='utf-8')
    m = MARKS.search(html)
    if not m:
        sys.exit(f'loadscreen_shots: no shots:begin / shots:end markers in {PAGE}')
    indent = re.search(r'([ \t]*)$', html[:m.start()]).group(1)
    body = ''.join(f"\n{indent}  'shots/{n}'," for n in names)
    html = html[:m.start()] + m.group(1) + body + '\n' + m.group(3) + html[m.end():]
    PAGE.write_text(html, encoding='utf-8', newline='\n')


def listing():
    have = sorted(f for f in SHOTS.iterdir() if OURS.match(f.name)) if SHOTS.is_dir() else []
    total = 0
    for f in have:
        with Image.open(f) as im:
            w, h = im.size
        total += f.stat().st_size
        print(f'  {f.name}  {w}x{h}  {f.stat().st_size / 1024:6.0f} KB')
    print(f'{len(have)} stills, {total / 1024:.0f} KB')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('sources', nargs='*', help='images or folders of images, in reel order')
    ap.add_argument('--list', action='store_true', help='show the current set and stop')
    a = ap.parse_args()
    if a.list:
        listing()
        return
    if not a.sources:
        ap.error('give at least one image or folder')

    srcs = gather(a.sources)
    if len(srcs) > 99:
        sys.exit('loadscreen_shots: 99 stills at most')
    SHOTS.mkdir(parents=True, exist_ok=True)

    # Encode everything before touching the old set, so a source that will not
    # open leaves the set as it was rather than half replaced.
    out = []
    for i, src in enumerate(srcs, 1):
        try:
            with Image.open(src) as im:
                im.load()
                im = srgb(im)   # upright first, so a rotated photo is measured the way it is shown
                small = im.width < SIZE[0] or im.height < SIZE[1]
                im = ImageOps.fit(im, SIZE, Image.LANCZOS, centering=(0.5, 0.5))
        except OSError as e:
            sys.exit(f'loadscreen_shots: cannot read {src}: {e}')
        q, data = encode(im)
        out.append((f'{i:02d}.webp', src, q, data, small))

    for f in SHOTS.iterdir():
        if OURS.match(f.name):
            f.unlink()
    total = 0
    for name, src, q, data, small in out:
        (SHOTS / name).write_bytes(data)
        total += len(data)
        notes = []
        if small:
            notes.append('smaller than 1920x1080: upscaled, so it will look soft')
        if len(data) > MAX_BYTES:
            notes.append(f'over {MAX_BYTES // 1024} KB even at quality {q}')
        print(f'  {name}  q{q:<3} {len(data) / 1024:6.0f} KB  <- {src}'
              + (f'   [{"; ".join(notes)}]' if notes else ''))
    rewrite_page([n for n, *_ in out])
    print(f'{len(out)} stills, {total / 1024:.0f} KB, into {SHOTS.relative_to(ROOT)}; '
          f'{PAGE.relative_to(ROOT)} lists them')


if __name__ == '__main__':
    main()
