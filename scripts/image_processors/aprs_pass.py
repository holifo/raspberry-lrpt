#!/usr/bin/env python3
'''
APRS heard through the ISS during one pass (iss_aprs): turns direwolf's packet log into the pass's
data file and map picture.

  aprs_pass.py CSV PACKETS TLE SAT START END LAT LON OUT_PREFIX
  aprs_pass.py --follow      (stdin: the -L log as it grows; prints one line per packet)

  CSV        direwolf's -L log (one row per decoded packet: time, source, position, comment, ...)
  PACKETS    direwolf's own output, for the packets as sent ("[0.3] SRC>DEST,PATH:info" lines)
  TLE        3-line TLE file with SAT in it (for the ground track)
  START/END  the pass, epoch seconds
  LAT/LON    the station
  OUT_PREFIX writes OUT_PREFIX-aprs.json and OUT_PREFIX-aprs-map.png

Prints the number of stations heard (0 = nothing decoded; no files are written then).
The map uses SatDump's Natural Earth coastline when it is installed.
'''

import csv
import datetime
import json
import os
import re
import struct
import sys
from math import asin, cos, radians, sin, sqrt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import polar_plot as pp            # palette, TLE reader, card figure, local time
import ephem
import matplotlib.patheffects as pe

COAST = '/usr/share/satdump/resources/maps/ne_10m_coastline.shp'
ISS_DIGI = re.compile(r'(RS0ISS|NA1SS|ARISS)', re.I)
PKT_LINE = re.compile(r'^\[[^\]]*\]\s+(\S+?)>(\S*?):(.*)$')


def read_packets(csv_file, raw_file):
  rows = []
  with open(csv_file, newline='', errors='replace') as f:
    for r in csv.DictReader(f):
      if r.get('source'):
        rows.append(r)
  raws = []
  if raw_file and os.path.exists(raw_file):
    with open(raw_file, errors='replace') as f:
      for line in f:
        m = PKT_LINE.match(line.strip())
        if m:
          raws.append(line.strip().split(' ', 1)[1].replace('<0x0a>', '').replace('<0x0d>', ''))
  packets = []
  for i, r in enumerate(rows):
    def num(k):
      try:
        return round(float(r.get(k) or ''), 5)
      except ValueError:
        return None
    raw = raws[i] if len(raws) == len(rows) else ''
    packets.append({
      'time': int(float(r.get('utime') or 0)),
      'call': r['source'].strip(),
      'heard': (r.get('heard') or '').strip(),
      'via_iss': bool(ISS_DIGI.search((r.get('heard') or '') + ' ' + raw.split(':', 1)[0])),
      'type': (r.get('dti') or '').strip(),
      'symbol': (r.get('symbol') or '').strip(),
      'lat': num('latitude'), 'lon': num('longitude'),
      'comment': ((r.get('comment') or '') or (r.get('status') or '')).strip()[:160],
      'device': (r.get('system') or '').strip()[:60],
      'raw': raw[:300],
    })
  return packets


def stations_of(packets):
  st = {}
  for p in packets:
    s = st.setdefault(p['call'], {'call': p['call'], 'packets': 0, 'first': p['time'], 'last': p['time'],
                                  'lat': None, 'lon': None, 'symbol': '', 'comment': '', 'via_iss': False})
    s['packets'] += 1
    s['first'], s['last'] = min(s['first'], p['time']), max(s['last'], p['time'])
    s['via_iss'] = s['via_iss'] or p['via_iss']
    if p['lat'] is not None and p['lon'] is not None:
      s['lat'], s['lon'], s['symbol'] = p['lat'], p['lon'], p['symbol']
    if p['comment']:
      s['comment'] = p['comment']
  return sorted(st.values(), key=lambda s: s['first'])


def ground_track(tle, sat_name, start, end, step=10):
  sat = pp.get_sat(tle, sat_name)
  if sat is None:
    return []
  out = []
  for t in list(range(start, end, step)) + [end]:
    sat.compute(datetime.datetime.fromtimestamp(t, datetime.timezone.utc).replace(tzinfo=None))
    out.append([round(float(sat.sublong) * 57.29578, 3), round(float(sat.sublat) * 57.29578, 3)])
  return out


def coastlines(box):
  '''Polylines of the Natural Earth coastline (shapefile type 3) that touch box (W, S, E, N).'''
  w, s, e, n = box
  lines = []
  try:
    with open(COAST, 'rb') as f:
      data = f.read()
  except OSError:
    return lines
  pos = 100
  while pos + 8 <= len(data):
    clen = struct.unpack('>i', data[pos + 4:pos + 8])[0] * 2
    rec = data[pos + 8:pos + 8 + clen]
    pos += 8 + clen
    if len(rec) < 44 or struct.unpack('<i', rec[:4])[0] != 3:
      continue
    x0, y0, x1, y1 = struct.unpack('<4d', rec[4:36])
    if x1 < w or x0 > e or y1 < s or y0 > n:
      continue
    nparts, npts = struct.unpack('<2i', rec[36:44])
    parts = list(struct.unpack('<%di' % nparts, rec[44:44 + 4 * nparts])) + [npts]
    pts = struct.unpack('<%dd' % (2 * npts), rec[44 + 4 * nparts:44 + 4 * nparts + 16 * npts])
    for a, b in zip(parts[:-1], parts[1:]):
      lines.append((pts[2 * a:2 * b:2], pts[2 * a + 1:2 * b:2]))
  return lines


def draw_map(out_file, stations, track, lat, lon, start, n_packets):
  pts = [(s['lon'], s['lat']) for s in stations if s['lat'] is not None] + [(lon, lat)] + \
        [tuple(p) for p in track]
  xs, ys = [p[0] for p in pts], [p[1] for p in pts]
  w, e, s, n = min(xs) - 3, max(xs) + 3, max(min(ys) - 3, -85), min(max(ys) + 3, 85)
  aspect = 1 / max(cos(radians((s + n) / 2)), 0.2)
  # widen to the card's shape (10 x 6.2 map area) so a short pass is not stretched
  want = 10 / 6.2
  if (e - w) / ((n - s) * aspect) < want:
    pad = ((n - s) * aspect * want - (e - w)) / 2
    w, e = w - pad, e + pad
  else:
    pad = ((e - w) / want / aspect - (n - s)) / 2
    s, n = max(s - pad, -85), min(n + pad, 85)

  fig, png = pp.new_figure(out_file, 10, 7.4)
  colour = pp.SAT_COLOURS['ISS']
  fig.text(0.04, 0.965, 'ISS', fontsize=17, fontweight='bold', color=colour, va='top')
  fig.text(0.96, 0.965, 'APRS 145.825 MHz', fontsize=11, color=pp.DIM, va='top', ha='right')
  fig.text(0.04, 0.915, '{}  ·  {} station{} heard  ·  {} packet{}'.format(
             pp.local(start).strftime('%a %d/%m/%Y %H:%M %Z'), len(stations), '' if len(stations) == 1 else 's',
             n_packets, '' if n_packets == 1 else 's'), fontsize=11, color=pp.TEXT, va='top')
  ax = fig.add_axes([0.04, 0.06, 0.92, 0.80])
  ax.set_facecolor(pp.PANEL)
  for sp in ax.spines.values():
    sp.set_color('#2a3a50')
  for xs_, ys_ in coastlines((w - 1, s - 1, e + 1, n + 1)):
    ax.plot(xs_, ys_, color='#4a6382', linewidth=0.6)
  if len(track) >= 2:
    tx, ty = [p[0] for p in track], [p[1] for p in track]
    ax.plot(tx, ty, color=colour, linewidth=2.2, alpha=0.9)
    ax.annotate('', xy=(tx[-1], ty[-1]), xytext=(tx[-2], ty[-2]),
                arrowprops=dict(arrowstyle='-|>', color=colour, lw=2))
  halo = [pe.withStroke(linewidth=3, foreground=pp.PANEL)]
  for st in stations:
    if st['lat'] is None:
      continue
    c = '#9fd3ff' if st['via_iss'] else '#8fa3b8'
    ax.plot(st['lon'], st['lat'], 'o', color=c, markersize=6, markeredgecolor=pp.PANEL, markeredgewidth=1)
    ax.text(st['lon'], st['lat'], ' ' + st['call'], color=pp.TEXT, fontsize=8.5, va='bottom', path_effects=halo)
  ax.plot(lon, lat, marker='*', color=pp.LOS_C, markersize=13, markeredgecolor=pp.PANEL)
  ax.set_xlim(w, e)
  ax.set_ylim(s, n)
  ax.set_aspect(aspect)
  ax.tick_params(labelsize=8)
  ax.grid(color=pp.GRID, linewidth=0.5)
  unplaced = [st['call'] for st in stations if st['lat'] is None]
  note = 'Track of the ISS during the pass  ·  ★ this station  ·  dots: stations heard through the ISS'
  if unplaced:
    note += '  ·  no position: ' + ', '.join(unplaced[:8]) + (' …' if len(unplaced) > 8 else '')
  fig.text(0.5, 0.015, note, fontsize=8.5, color=pp.RING_TXT, ha='center', va='bottom')
  pp.save(fig, out_file, png)


def follow():
  """--follow: read direwolf's -L log as it grows (tail -F on stdin) and print one line per packet
  for the station log: "N0CALL-7 via RS0ISS · 38.25 N 21.73 E · \"comment\"" """
  head = None
  for line in sys.stdin:
    line = line.rstrip('\r\n')
    if not line:
      continue
    row = next(csv.reader([line]), [])
    if row and row[0] == 'chan':
      head = row
      continue
    if not head or len(row) != len(head):
      continue
    r = dict(zip(head, row))
    call = (r.get('source') or '').strip()
    if not call:
      continue
    heard = (r.get('heard') or '').strip()
    out = call + (' via ' + heard if ISS_DIGI.search(heard) else ' (direct)')
    try:
      la, lo = float(r.get('latitude') or ''), float(r.get('longitude') or '')
      out += ' · {:.2f} {} {:.2f} {}'.format(abs(la), 'N' if la >= 0 else 'S', abs(lo), 'E' if lo >= 0 else 'W')
    except ValueError:
      pass
    text = ((r.get('comment') or '') or (r.get('status') or '')).strip().replace('\n', ' ')[:80]
    if text:
      out += ' · "' + text + '"'
    print(out, flush=True)


def main():
  if len(sys.argv) == 2 and sys.argv[1] == '--follow':
    follow()
    return
  if len(sys.argv) != 10:
    print(__doc__)
    sys.exit(1)
  csv_file, raw_file, tle, sat = sys.argv[1:5]
  start, end = int(sys.argv[5]), int(sys.argv[6])
  lat, lon, prefix = float(sys.argv[7]), float(sys.argv[8]), sys.argv[9]

  packets = read_packets(csv_file, raw_file) if os.path.exists(csv_file) else []
  stations = stations_of(packets)
  if not stations:
    print(0)
    return
  for s in stations:                     # great-circle distance from this station, km
    s['km'] = None
    if s['lat'] is not None:
      h = sin(radians(s['lat'] - lat) / 2) ** 2 + cos(radians(lat)) * cos(radians(s['lat'])) * sin(radians(s['lon'] - lon) / 2) ** 2
      s['km'] = int(round(2 * 6371 * asin(sqrt(min(1, h)))))
  try:
    track = ground_track(tle, sat, start, end)
  except Exception as e:                 # old or missing orbit data: no track, the rest stays
    print('APRS track failed: {}'.format(e), file=sys.stderr)
    track = []
  with open(prefix + '-aprs.json', 'w') as f:
    json.dump({'start': start, 'end': end, 'frequency': 145.825, 'station': [lon, lat],
               'stations': stations, 'packets': packets, 'track': track}, f, separators=(',', ':'))
  try:
    draw_map(prefix + '-aprs-map.png', stations, track, lat, lon, start, len(packets))
  except Exception as e:                 # keep the pass even without its picture
    print('APRS map failed: {}'.format(e), file=sys.stderr)
  print(len(stations))


if __name__ == '__main__':
  main()
