#!/usr/bin/env python3
#
# Cut a SatDump projection down to the pass and put it on the station's dark blue.
#
#   crop_to_swath.py IN.png OUT.png [--keep]
#
# SatDump draws the borders, coastlines, station and city names everywhere on the map, also
# outside the pass, so the opaque pixels alone don't show where the pass is. The thin lines and
# letters go away when the opaque area is shrunk by a few pixels (an erosion); what is left is the
# pass, whose box (grown back, plus a small margin) is the crop. With --keep the picture keeps
# its size (a fixed area) and is only checked for coverage.
#
# Prints one line for the log. Writes nothing when the pass covers under 3 % of the picture.

import sys

import numpy as np
from PIL import Image, ImageFilter

BG = (11, 18, 32)
ERODE = 9          # px: wider than any line or letter stroke
MARGIN = 12        # px around the pass


def main(src, out, keep):
    im = Image.open(src)
    if im.mode not in ('RGBA', 'LA'):
        im = im.convert('RGBA')
    im = im.convert('RGBA')
    alpha = im.getchannel('A').point(lambda v: 255 if v > 0 else 0)
    core = np.asarray(alpha.filter(ImageFilter.MinFilter(ERODE))) > 0
    share = core.mean()
    if share < 0.03:
        print('Capitals map: the pass hardly covers the area (%.1f %%) - none made' % (100 * share))
        return 0
    if not keep:
        ys, xs = np.nonzero(core)
        grow = ERODE // 2 + MARGIN
        box = (max(0, xs.min() - grow), max(0, ys.min() - grow),
               min(im.width, xs.max() + 1 + grow), min(im.height, ys.max() + 1 + grow))
        im = im.crop(box)
    flat = Image.new('RGB', im.size, BG)
    flat.paste(im, mask=im.getchannel('A'))
    flat.save(out)
    print('Capitals map made (%dx%d)' % flat.size)
    return 0


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 2:
        sys.exit('Usage: crop_to_swath.py IN.png OUT.png [--keep]')
    sys.exit(main(args[0], args[1], '--keep' in sys.argv))
