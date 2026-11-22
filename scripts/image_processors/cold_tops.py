#!/usr/bin/env python3
#
# "Coldest cloud tops" for a night pass, from the raw 3.7 um channel (MSU-MR channel 4).
#
#   cold_tops.py IN OUT
#
# IN is the geo-corrected channel 4 image (SatDump's "MSU-MR Channel 4" composite:
# msu_mr_rgb_MSU-MR_Channel_4_corrected.png, bright = warm). OUT is written as a colour image:
# the IR picture in grey (cold = light) with the pass's coldest cloud tops coloured green,
# yellow and red, coldest last. Tall, cold-topped clouds are where showers and storms are likely.
#
# This is RELATIVE: the METEORs currently send no calibration (no temperatures), so "cold" means
# colder than the rest of this pass, not a set temperature, and it is not a rain measurement.
# With calibration back, SatDump's own "Rain Likelihood" composites (rl1_rain.png LUT) take over.
# Only for night passes: by day channel 4 also sees reflected sunlight, which hides cold tops.
#
# Prints one line (logged by receive_meteor.sh). Never fails the pass: on any problem it writes
# nothing and says why.

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# (share of the pass, distance below the middle as a share of the spread, colour): a pixel needs
# both, so a pass with a big cold cloud mass doesn't turn mostly red (the sensor's cold end is
# flat: about 2 % of a real night pass sat on its lowest value)
TIERS = [(12.0, 0.60, (67, 160, 71)),    # green
         (6.0, 0.80, (253, 216, 53)),    # yellow
         (2.5, 0.95, (229, 57, 53))]     # red, the coldest
DISTINCT = 0.25                    # the cold tail must reach this far below the middle, else no colour
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'


def main(src, dst, flip=False):
    a = np.asarray(Image.open(src).convert('L')).astype(np.float32)
    valid = a > 0                                         # fill (missing lines) is 0
    if valid.mean() < 0.05:
        print('Cold cloud tops: no channel 4 picture in this pass')
        return 0
    v = a[valid]
    p1, p50, p99 = np.percentile(v, [1, 50, 99])
    spread = p50 - p1                                     # how far the coldest 1 % is below the middle
    full = max(p99 - p1, 1.0)

    # base: the IR picture, cold = light, a little dimmed so the colours stand out
    grey = np.clip((p99 - a) / full, 0, 1) * 200 + 25
    grey[~valid] = 0
    rgb = np.repeat(grey[..., None], 3, axis=2)

    coloured = 0.0
    if spread / full >= DISTINCT:
        masks = []
        for share, frac, colour in TIERS:
            m = valid & (a <= min(np.percentile(v, share), p50 - frac * spread))
            rgb[m] = rgb[m] * 0.25 + np.array(colour, np.float32) * 0.75
            masks.append(m)
        coloured = float(masks[0].sum()) / float(valid.sum())

    img = Image.fromarray(rgb.astype(np.uint8), 'RGB')
    legend(img, coloured > 0, flip)
    tmp = dst + '.tmp.png'
    img.save(tmp)
    os.replace(tmp, dst)
    if coloured > 0:
        print('Cold cloud tops: %.1f %% of the pass coloured (relative to this pass, not a rain measurement)'
              % (coloured * 100))
    else:
        print('Cold cloud tops: no distinctly cold cloud tops in this pass')
    return 0


def legend(img, any_colour, flip=False):
    """The legend box, top left. With flip (a northbound pass the station turns 180° afterwards)
    it is drawn upside down in the bottom-right corner, so it ends up top left and upright."""
    w = img.width
    s = max(1.0, w / 1568)                                # sized for a full-width MSU-MR image
    try:
        font = ImageFont.truetype(FONT, int(15 * s))
        bold = ImageFont.truetype(FONT.replace('Sans.ttf', 'Sans-Bold.ttf'), int(16 * s))
    except OSError:
        font = bold = ImageFont.load_default()
    d = ImageDraw.Draw(img, 'RGBA')
    pad, sw = int(10 * s), int(22 * s)
    rows = [((229, 57, 53), 'coldest'), ((253, 216, 53), 'colder'), ((67, 160, 71), 'cold')]
    lines = ['Coldest cloud tops', 'relative to this pass, not a rain measurement']
    box_w = int(430 * s)
    box_h = pad * 2 + int(22 * s) + int(20 * s) + (len(rows) * int(26 * s) if any_colour else int(24 * s))
    box = Image.new('RGBA', (box_w + 1, box_h + 1), (0, 0, 0, 0))
    d = ImageDraw.Draw(box, 'RGBA')
    x0, y0 = 0, 0
    d.rounded_rectangle([x0, y0, x0 + box_w, y0 + box_h], radius=int(8 * s), fill=(11, 18, 32, 200))
    y = y0 + pad
    d.text((x0 + pad, y), lines[0], font=bold, fill=(255, 255, 255))
    y += int(22 * s)
    d.text((x0 + pad, y), lines[1], font=font, fill=(190, 200, 215))
    y += int(26 * s)
    if not any_colour:
        d.text((x0 + pad, y), 'none distinctly cold in this pass', font=font, fill=(255, 255, 255))
    else:
        for colour, text in rows:
            d.rectangle([x0 + pad, y + 2, x0 + pad + sw, y + int(18 * s)], fill=colour + (255,))
            d.text((x0 + pad * 2 + sw, y), text, font=font, fill=(255, 255, 255))
            y += int(26 * s)
    if flip:
        box = box.rotate(180)
        img.paste(box, (img.width - pad - box.width, img.height - pad - box.height), box)
    else:
        img.paste(box, (pad, pad), box)


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--flip']
    if len(args) != 2:
        sys.exit('Usage: cold_tops.py CHANNEL4_CORRECTED.png OUT.png [--flip]')
    try:
        sys.exit(main(args[0], args[1], '--flip' in sys.argv))
    except Exception as e:                               # never stop the pass for this
        print('Cold cloud tops: not made (%s)' % e)
        sys.exit(0)
