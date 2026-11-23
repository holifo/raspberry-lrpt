#!/usr/bin/env python3
#
# The sun's elevation (whole degrees) at the station at a given time.
#
#   sun.py EPOCH      e.g. sun.py 1795999999  ->  -37
#
# The station's position comes from LAT / LON in the environment, else from the LAT= and LON=
# lines of ~/.raspberry-lrpt.conf. (It used the envbash package for that until v1.40.1; envbash
# imports the "pipes" module, which Python 3.13 - Debian Trixie - no longer has.)

import os
import re
import sys
from datetime import datetime, timezone

import ephem


def station():
    lat, lon = os.environ.get('LAT'), os.environ.get('LON')
    if lat and lon:
        return lat, lon
    conf = os.path.expanduser('~/.raspberry-lrpt.conf')
    values = {}
    try:
        with open(conf) as f:
            for line in f:
                m = re.match(r'\s*(?:export\s+)?(LAT|LON)=["\']?([-+0-9.]+)', line)
                if m:
                    values[m.group(1)] = m.group(2)
    except OSError as e:
        sys.exit('sun.py: cannot read %s: %s' % (conf, e))
    if 'LAT' not in values or 'LON' not in values:
        sys.exit('sun.py: no LAT / LON in %s' % conf)
    return values['LAT'], values['LON']


def main():
    if len(sys.argv) != 2:
        sys.exit('Usage: sun.py EPOCH')
    lat, lon = station()
    obs = ephem.Observer()
    obs.lat = str(lat)
    obs.long = str(lon)
    obs.date = datetime.fromtimestamp(int(float(sys.argv[1])), tz=timezone.utc).replace(tzinfo=None)
    sun = ephem.Sun(obs)
    print(int(float(sun.alt) * 57.2957795))      # radians to degrees, cut to whole degrees as before


if __name__ == '__main__':
    main()
