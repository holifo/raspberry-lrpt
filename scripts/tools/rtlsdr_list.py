#!/usr/bin/env python3
"""The RTL-SDR dongles on this station, and which one the ISS recorder uses.

  rtlsdr_list.py                       list them: index, maker, model, serial (tab-separated)
  rtlsdr_list.py pick WANT METEOR RX   print "<index> <mode>" for the ISS recording, mode being
                                       dedicated (its own dongle: records alongside the Meteors),
                                       shared (the Meteors' dongle: Meteor passes come first) or
                                       none (no RTL-SDR: prints "- none")

WANT is iss_sdr_device: empty = choose automatically, else an index, a serial number, or part of
the serial or of the maker/model text (e.g. "Blog V4"). METEOR is the index the Meteors record on
(meteor_m2_3_sdr_device_id with use_device_string, else 0); RX is receiver_type: with any other
receiver than rtlsdr the Meteors use no RTL-SDR, so every dongle is free for the ISS.

The names come from librtlsdr without opening the dongle, so a dongle that is recording is listed
too. RL1_FAKE_RTLSDR="maker|model|serial;..." replaces the hardware (tests).
"""
import ctypes
import ctypes.util
import os
import sys


def devices():
    fake = os.environ.get('RL1_FAKE_RTLSDR')
    if fake is not None:
        return [tuple(d.split('|')) for d in fake.split(';') if d]
    name = ctypes.util.find_library('rtlsdr') or 'librtlsdr.so.0'
    try:
        lib = ctypes.CDLL(name)
    except OSError:
        return []
    lib.rtlsdr_get_device_count.restype = ctypes.c_uint32
    found = []
    for i in range(lib.rtlsdr_get_device_count()):
        m, p, s = (ctypes.create_string_buffer(256) for _ in range(3))
        if lib.rtlsdr_get_device_usb_strings(ctypes.c_uint32(i), m, p, s) != 0:
            m.value = p.value = s.value = b''
        found.append(tuple(x.value.decode(errors='replace').strip() for x in (m, p, s)))
    return found


def resolve(want, devs):
    """The index iss_sdr_device names, or None."""
    want = want.strip()
    if not want:
        return None
    if want.isdigit() and int(want) < len(devs):
        return int(want)
    low = want.lower()
    for test in (lambda d: d[2] == want,                          # the exact serial
                 lambda d: low in d[2].lower(),                   # part of the serial
                 lambda d: low in (d[0] + ' ' + d[1]).lower()):   # part of maker + model
        hits = [i for i, d in enumerate(devs) if test(d)]
        if hits:
            return hits[0]
    return None


def pick(want, meteor, receiver, devs):
    if not devs:
        return None, 'none'
    meteor_idx = meteor if receiver == 'rtlsdr' else None
    idx = resolve(want, devs)
    if want.strip() and idx is None:
        print('iss_sdr_device "{}" matches no RTL-SDR - choosing one automatically'.format(want),
              file=sys.stderr)
    if idx is None:
        free = [i for i in range(len(devs)) if i != meteor_idx]
        idx = free[0] if free else meteor_idx
    if idx is None:                  # only the Meteors' index, and it is not connected
        return None, 'none'
    return idx, ('shared' if idx == meteor_idx else 'dedicated')


def main():
    devs = devices()
    if len(sys.argv) == 1:
        for i, (m, p, s) in enumerate(devs):
            print('{}\t{}\t{}\t{}'.format(i, m or '?', p or '?', s or '-'))
        return 0
    if sys.argv[1] == 'pick' and len(sys.argv) == 5:
        try:
            meteor = int(sys.argv[3] or 0)
        except ValueError:
            meteor = 0
        idx, mode = pick(sys.argv[2], meteor, sys.argv[4], devs)
        print('{} {}'.format('-' if idx is None else idx, mode))
        return 0
    print(__doc__.strip().split('\n\n')[1], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
