#!/usr/bin/env python3
#
# Blend the passes of a daily map into one seamless picture.
#
#   blend_layers.py OUT.png OVERLAY.png OVERLAY_BASE.png LAYER.png...
#
# Each LAYER is one pass projected onto the map by SatDump without borders (RGBA: transparent
# outside the swath). Where passes overlap, the one that saw the spot closer to its swath's
# middle wins (the edges of a swath are stretched and blurred), with a soft hand-over between
# them instead of a hard edge: each layer's weight is its blurred swath mask, raised to a power,
# so the more central pass dominates and the change from one to the next is gradual.
#
# OVERLAY is one pass projected again WITH the borders, coastlines, station and capitals, and
# OVERLAY_BASE the same pass without them: the pixels that differ are the lines, which are drawn
# once on top of the blend. Outside every swath the map is the station's dark blue (#0b1220).
#
# Memory: the sums are kept per channel in float32, so a 2800 x 2000 map needs about 100 MB
# whatever the number of passes.

import sys

import numpy as np
from PIL import Image, ImageFilter

BG = np.array([11, 18, 32], np.float32)
BLUR_DIV = 4          # the weights are worked out at a quarter of the size, then scaled up
BLUR_RADIUS = 30      # at that size: about 120 px (3°) on the full map
POWER = 3.0           # how strongly the more central pass wins


def weight(alpha):
    """Weight of a layer: high in the middle of its swath, falling to 0 at its edges."""
    h, w = alpha.shape
    m = Image.fromarray(alpha)
    small = m.resize((max(1, w // BLUR_DIV), max(1, h // BLUR_DIV)), Image.BILINEAR)
    # pad first, so the blur treats the map's border as "outside the swath" too
    pad = BLUR_RADIUS * 3
    big = Image.new('L', (small.width + 2 * pad, small.height + 2 * pad), 0)
    big.paste(small, (pad, pad))
    blurred = big.filter(ImageFilter.GaussianBlur(BLUR_RADIUS)).crop(
        (pad, pad, pad + small.width, pad + small.height)).resize((w, h), Image.BILINEAR)
    wgt = (np.asarray(blurred, np.float32) / 255.0) ** POWER
    return wgt * (alpha.astype(np.float32) / 255.0) + 1e-6 * (alpha > 0)


def main(out, overlay, overlay_base, layers):
    acc = None
    accw = None
    for path in layers:
        try:
            im = np.asarray(Image.open(path).convert('RGBA'))
        except Exception as e:
            print('Daily map blend: skipping %s (%s)' % (path, e))
            continue
        wgt = weight(im[..., 3])
        if acc is None:
            acc = np.zeros(im.shape[:2] + (3,), np.float32)
            accw = np.zeros(im.shape[:2], np.float32)
        for c in range(3):
            acc[..., c] += im[..., c].astype(np.float32) * wgt
        accw += wgt
        del im, wgt
    if acc is None:
        print('Daily map blend: no layers')
        return 1
    covered = accw > 0
    rgb = np.empty_like(acc)
    for c in range(3):
        rgb[..., c] = np.where(covered, acc[..., c] / np.maximum(accw, 1e-12), BG[c])
    del acc

    # the lines (borders, coastlines, station, capitals), once, on top
    try:
        ov = np.asarray(Image.open(overlay).convert('RGBA'))
        base = np.asarray(Image.open(overlay_base).convert('RGBA'))
        diff = np.abs(ov[..., :3].astype(np.int16) - base[..., :3].astype(np.int16)).max(axis=2)
        lines = ((diff > 24) & (ov[..., 3] > 0)) | ((base[..., 3] == 0) & (ov[..., 3] > 0))
        rgb[lines] = ov[..., :3][lines]
    except Exception as e:
        print('Daily map blend: no borders drawn (%s)' % e)

    Image.fromarray(np.clip(rgb + 0.5, 0, 255).astype(np.uint8), 'RGB').save(out)
    print('Daily map blend: %d passes blended, %.0f %% of the map covered'
          % (len(layers), 100.0 * covered.mean()))
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 5:
        sys.exit('Usage: blend_layers.py OUT.png OVERLAY.png OVERLAY_BASE.png LAYER.png...')
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]))
