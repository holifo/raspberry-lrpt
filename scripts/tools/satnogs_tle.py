#!/usr/bin/env python3
'''
TLEs from the SatNOGS DB (db.satnogs.org, Libre Space Foundation; no account needed), the backup
when CelesTrak can't be reached (schedule.sh).

  satnogs_tle.py OUT NORAD=NAME [NORAD=NAME ...]

Writes OUT as a 3-line TLE file with the given name lines (e.g. 57166="METEOR-M2 3", so it reads
like CelesTrak's file) and exits 0 only when every satellite was found. Each satellite is asked
for on its own; the answer is checked against the NORAD number, whatever the API sends back.
'''

import json
import os
import sys
import urllib.request

API = 'https://db.satnogs.org/api/tle/?format=json&norad_cat_id={}'


def fetch(norad):
    req = urllib.request.Request(API.format(norad), headers={'User-Agent': 'raspberry-lrpt'})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    for rec in data if isinstance(data, list) else []:
        l1, l2 = (rec.get('tle1') or '').strip(), (rec.get('tle2') or '').strip()
        if str(rec.get('norad_cat_id')) == str(norad) and l1.startswith('1 ' + norad) and l2.startswith('2 ' + norad):
            return l1, l2
    return None


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    out, lines, missing = sys.argv[1], [], []
    for arg in sys.argv[2:]:
        norad, _, name = arg.partition('=')
        try:
            tle = fetch(norad)
        except Exception as e:
            print('SatNOGS: {} failed: {}'.format(norad, e), file=sys.stderr)
            tle = None
        if tle:
            lines += [name or norad, tle[0], tle[1]]
        else:
            missing.append(norad)
    if missing:
        print('SatNOGS: no TLE for ' + ' '.join(missing), file=sys.stderr)
        sys.exit(1)
    tmp = out + '.part'
    with open(tmp, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    os.replace(tmp, out)


if __name__ == '__main__':
    main()
