#!/usr/bin/env python3
'''
TLEs from a backup source, for when CelesTrak can't be reached (schedule.sh tries them in this
order). None of them needs an account.

  backup_tle.py SOURCE OUT NORAD=NAME [NORAD=NAME ...]

SOURCE
  tleapi   TLE API (tle.ivanstanojevic.me, listed in NASA's API catalogue; a copy of CelesTrak's
           data, served from another server), one request per satellite
  amsat    AMSAT's daily file (www.amsat.org/tle/dailytle.txt): the satellites radio amateurs
           use, updated at least daily; one download for all
  satnogs  the SatNOGS DB (db.satnogs.org, Libre Space Foundation), one request per satellite

Writes OUT as a 3-line TLE file with the given name lines (e.g. 57166="METEOR-M2 3", so it reads
like CelesTrak's file) and exits 0 only when every satellite was found. Each pair of lines must
carry the asked NORAD number and pass the TLE checksum, whatever the source sends back.
'''

import json
import os
import sys
import urllib.request

UA = {'User-Agent': 'raspberry-lrpt (weather satellite ground station)'}
TLEAPI = 'https://tle.ivanstanojevic.me/api/tle/{}'
AMSAT = 'https://www.amsat.org/tle/dailytle.txt'
SATNOGS = 'https://db.satnogs.org/api/tle/?format=json&norad_cat_id={}'


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
        return r.read().decode('utf-8', 'replace')


def checksum_ok(line):
    """The last digit of a TLE line is the sum of its digits (a '-' counts 1) modulo 10."""
    line = line.rstrip()
    if len(line) != 69 or not line[68].isdigit():
        return False
    s = sum(int(c) if c.isdigit() else (1 if c == '-' else 0) for c in line[:68])
    return s % 10 == int(line[68])


def valid(norad, l1, l2):
    l1, l2 = (l1 or '').strip(), (l2 or '').strip()
    if l1.startswith('1 ' + norad) and l2.startswith('2 ' + norad) and checksum_ok(l1) and checksum_ok(l2):
        return l1, l2
    return None


def from_tleapi(norad):
    d = json.loads(get(TLEAPI.format(norad)))
    if str(d.get('satelliteId')) == str(norad):
        return valid(norad, d.get('line1'), d.get('line2'))
    return None


def from_satnogs(norad):
    data = json.loads(get(SATNOGS.format(norad)))
    for rec in data if isinstance(data, list) else []:
        if str(rec.get('norad_cat_id')) == str(norad):
            tle = valid(norad, rec.get('tle1'), rec.get('tle2'))
            if tle:
                return tle
    return None


def amsat_lookup():
    lines = [l.strip() for l in get(AMSAT).splitlines()]
    def find(norad):
        for i in range(len(lines) - 1):
            if lines[i].startswith('1 ' + norad):
                return valid(norad, lines[i], lines[i + 1])
        return None
    return find


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ('tleapi', 'amsat', 'satnogs'):
        print(__doc__)
        sys.exit(2)
    source, out, lines, missing = sys.argv[1], sys.argv[2], [], []
    label = {'tleapi': 'TLE API', 'amsat': 'AMSAT', 'satnogs': 'SatNOGS'}[source]
    fetch = {'tleapi': from_tleapi, 'satnogs': from_satnogs}.get(source)
    if source == 'amsat':
        try:
            fetch = amsat_lookup()
        except Exception as e:
            print('{}: download failed: {}'.format(label, e), file=sys.stderr)
            sys.exit(1)
    for arg in sys.argv[3:]:
        norad, _, name = arg.partition('=')
        try:
            tle = fetch(norad)
        except Exception as e:
            print('{}: {} failed: {}'.format(label, norad, e), file=sys.stderr)
            tle = None
        if tle:
            lines += [name or norad, tle[0], tle[1]]
        else:
            missing.append(norad)
    if missing:
        print('{}: no valid TLE for {}'.format(label, ' '.join(missing)), file=sys.stderr)
        sys.exit(1)
    tmp = out + '.part'
    with open(tmp, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    os.replace(tmp, out)


if __name__ == '__main__':
    main()
