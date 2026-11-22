#!/usr/bin/env python3
#
# Delete the images of a pass that are made from a channel with no picture in it.
#
#   drop_dark_images.py DIR [SATDUMP_CFG] [--dry-run]
#
# DIR is SatDump's "MSU-MR (Filled)" folder of a decoded pass, before receive_meteor.sh /
# reprocess_meteor.sh delete its raw channels (MSU-MR-1.png ... MSU-MR-6.png). A channel counts as
# empty when its pixels (fill left out) barely vary: on night passes channels 1-3 (reflected
# sunlight: 0.6, 0.8 and 1.6 um) are a flat dark level, and every composite made from them comes
# out white or yellow. Which composite uses which channel comes from SatDump's own
# satdump_cfg.json (its "equation" and "channels"), so new composites are handled too. A dawn or
# dusk pass with part of the swath in sunlight keeps its images.
#
# Prints one line per finding (receive_meteor.sh logs them). Never fails the pass: on any error
# it deletes nothing.

import json
import os
import re
import sys

SPREAD = 0.06          # 5th-95th percentile range (fraction of full scale) below which a channel is empty
CFG = '/usr/share/satdump/satdump_cfg.json'


def load_jsonc(path):
    """SatDump's config: JSON with // and /* */ comments and trailing commas."""
    with open(path, encoding='utf-8') as f:
        s = f.read()
    out, i, n, in_str = [], 0, len(s), False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(s[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j < 0 else j
            continue
        elif s.startswith('/*', i):
            j = s.find('*/', i)
            i = n if j < 0 else j + 2
            continue
        else:
            out.append(c)
        i += 1
    return json.loads(re.sub(r',(\s*[}\]])', r'\1', ''.join(out)))


def composites(cfg):
    """{file-name form of the composite: set of channel numbers}"""
    comp = load_jsonc(cfg)['viewer']['instruments']['msu_mr']['rgb_composites']
    out = {}
    for name, c in comp.items():
        text = ' '.join(str(c.get(k, '')) for k in ('equation', 'channels'))
        chans = set(int(x) for x in re.findall(r'\bc?ch(\d+)', text))
        if chans:
            out[name.replace(' ', '_').replace('µ', 'u')] = chans
    for n in range(1, 7):                                # the station's own per-channel images
        out.setdefault('MSU-MR_Channel_%d' % n, {n})
    return out


def empty_channels(folder):
    import numpy as np
    from PIL import Image
    found = {}
    for n in range(1, 7):
        path = os.path.join(folder, 'MSU-MR-%d.png' % n)
        if not os.path.isfile(path):
            continue
        a = np.asarray(Image.open(path))
        if a.ndim == 3:
            a = a[..., 0]
        full = 65535.0 if a.dtype == np.uint16 else 255.0
        v = a[::4, ::4].astype(np.float32) / full
        v = v[v > 0]                                     # fill (missing lines) is 0
        if v.size < 1000:
            continue
        p5, p95 = np.percentile(v, [5, 95])
        found[n] = (p95 - p5, p95 - p5 < SPREAD)
    return found


def main(argv):
    dry = '--dry-run' in argv
    args = [a for a in argv if a != '--dry-run']
    if not args:
        print(__doc__.split('\n\n')[1])
        return 1
    folder = args[0]
    cfg = args[1] if len(args) > 1 else CFG
    try:
        chans = empty_channels(folder)
        comp = composites(cfg)
    except Exception as e:                               # never stop the pass for this
        print('Could not check the channels for empty ones (%s) - keeping every image' % e)
        return 0
    empty = sorted(n for n, (_, e) in chans.items() if e)
    print('Channel picture check: ' + ', '.join(
        '%d %s (%.0f%%)' % (n, 'empty' if e else 'ok', s * 100) for n, (s, e) in sorted(chans.items())))
    if not empty:
        return 0
    names = sorted(comp, key=len, reverse=True)          # longest first: "MSA" vs "MSA_..."
    dropped = []
    for f in sorted(os.listdir(folder)):
        if not f.endswith('.png') or f.startswith('MSU-MR-'):
            continue
        stem = re.sub(r'^(rgb_msu_mr_rgb_|msu_mr_rgb_|rgb_msu_mr_|msu_mr_)', '', f[:-4])
        for name in names:
            if stem == name or stem.startswith(name + '_'):
                if comp[name] & set(empty):
                    dropped.append(f)
                    if not dry:
                        os.remove(os.path.join(folder, f))
                break
    if dropped:
        print('%s %d images made from empty channel%s %s: %s' % (
            'Would drop' if dry else 'Dropped', len(dropped), 's' if len(empty) > 1 else '',
            ', '.join(map(str, empty)),
            ', '.join(sorted(set(re.sub(r'_(corrected|projected|map)($|_.*)', '', re.sub(
                r'^(rgb_msu_mr_rgb_|msu_mr_rgb_)', '', d[:-4])) for d in dropped)))))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
