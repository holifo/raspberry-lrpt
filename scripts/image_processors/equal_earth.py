#!/usr/bin/env python3
"""
Re-project a lat/lon (equirectangular) map image to the Equal Earth projection.

SatDump 1.2.3 can only make equirectangular, stereographic, UTM and geostationary maps. The daily
maps and the time-lapse are made equirectangular and then warped with this script, so areas keep
their true size (at 36° N an equirectangular map is ~24% too wide).

Usage:
  equal_earth.py IN OUT --bounds W N E S [--lon0 L] [--background '#0b1220'] [--keep-alpha]

  IN       equirectangular image covering the box W N E S (degrees; the outer edges of the pixels)
  OUT      .png or .jpg; same width as IN, height from the projected area. Outside the map is the
           background colour, or transparent with --keep-alpha (PNG only)
  --lon0   central meridian (default: the middle of the box)

Each output pixel is mapped back to longitude/latitude (pyproj, PROJ's "eqearth") and sampled
from IN with bilinear interpolation, in strips of rows to keep the memory use small.
"""
import argparse
import sys

import numpy as np
from PIL import Image
from pyproj import Transformer


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('src')
    p.add_argument('dst')
    p.add_argument('--bounds', nargs=4, type=float, required=True, metavar=('W', 'N', 'E', 'S'))
    p.add_argument('--lon0', type=float)
    p.add_argument('--background', default='#0b1220')
    p.add_argument('--keep-alpha', action='store_true')
    p.add_argument('--quality', type=int, default=88)
    return p.parse_args()


def main():
    a = parse_args()
    west, north, east, south = a.bounds
    lon0 = a.lon0 if a.lon0 is not None else (west + east) / 2
    Image.MAX_IMAGE_PIXELS = None
    src = Image.open(a.src)
    has_alpha = src.mode in ('RGBA', 'LA') or (src.mode == 'P' and 'transparency' in src.info)
    img = np.asarray(src.convert('RGBA' if has_alpha else 'RGB'), dtype=np.float32)
    h, w, nch = img.shape

    crs = '+proj=eqearth +lon_0=%r +ellps=WGS84 +units=m +no_defs' % lon0
    fwd = Transformer.from_crs('EPSG:4326', crs, always_xy=True)
    inv = Transformer.from_crs(crs, 'EPSG:4326', always_xy=True)

    # the projected extent of the box: its edges, densely sampled
    t = np.linspace(0, 1, 400)
    lons = np.concatenate([west + (east - west) * t, np.full(400, east), east - (east - west) * t, np.full(400, west)])
    lats = np.concatenate([np.full(400, north), north - (north - south) * t, np.full(400, south), south + (north - south) * t])
    xs, ys = fwd.transform(lons, lats)
    xmin, xmax, ymin, ymax = xs.min(), xs.max(), ys.min(), ys.max()
    px = (xmax - xmin) / w
    ow = w
    oh = max(2, int(round((ymax - ymin) / px)))
    oh -= oh % 2                                     # even sizes suit video encoders

    out = np.zeros((oh, ow, 4), dtype=np.uint8)
    col_x = xmin + (np.arange(ow) + 0.5) * px
    step = 128
    for r0 in range(0, oh, step):
        r1 = min(oh, r0 + step)
        row_y = ymax - (np.arange(r0, r1) + 0.5) * px
        gx, gy = np.meshgrid(col_x, row_y)
        lon, lat = inv.transform(gx, gy)
        # input pixel coordinates (pixel centres at +0.5)
        fx = (lon - west) / (east - west) * w - 0.5
        fy = (north - lat) / (north - south) * h - 0.5
        ok = np.isfinite(fx) & np.isfinite(fy) & (fx >= -0.5) & (fx <= w - 0.5) & (fy >= -0.5) & (fy <= h - 0.5)
        fx = np.clip(np.nan_to_num(fx), 0, w - 1)
        fy = np.clip(np.nan_to_num(fy), 0, h - 1)
        x0 = np.floor(fx).astype(np.int32); y0 = np.floor(fy).astype(np.int32)
        x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
        dx = (fx - x0)[..., None]; dy = (fy - y0)[..., None]
        v = (img[y0, x0] * (1 - dx) * (1 - dy) + img[y0, x1] * dx * (1 - dy) +
             img[y1, x0] * (1 - dx) * dy + img[y1, x1] * dx * dy)
        block = np.zeros((r1 - r0, ow, 4), dtype=np.float32)
        block[..., :3] = v[..., :3]
        block[..., 3] = v[..., 3] if has_alpha else 255
        block[~ok] = 0
        out[r0:r1] = np.clip(block + 0.5, 0, 255).astype(np.uint8)

    res = Image.fromarray(out, 'RGBA')
    if a.keep_alpha and a.dst.lower().endswith('.png'):
        res.save(a.dst, optimize=False)
    else:
        bg = Image.new('RGBA', res.size, a.background)
        bg.alpha_composite(res)
        bg = bg.convert('RGB')
        if a.dst.lower().endswith(('.jpg', '.jpeg')):
            bg.save(a.dst, quality=a.quality)
        else:
            bg.save(a.dst)
    print('%dx%d' % (ow, oh))


if __name__ == '__main__':
    sys.exit(main())
