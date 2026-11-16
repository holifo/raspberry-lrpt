#!/usr/bin/env python3
#
# Purpose: Draw pass graphs for a Meteor pass, in the dark style of the web panel
#          (same colours as the Passes map, so they suit dark mode and still look
#          like a self-contained card in light mode).
#
# Input parameters:
#   1. Satellite name (as in the TLE file)
#   2. TLE file
#   3. Pass start (epoch seconds)
#   4. Pass end (epoch seconds)
#   5. Ground station latitude
#   6. Ground station longitude
#   7. Satellite min elevation
#   8. Satellite direction of travel (Northbound / Southbound)
#   9. Output filename (.png keeps rounded transparent corners, .jpg gets a solid background)
#  10. Plot type:
#        'direction' - sky view: overhead in the centre, horizon at the edge, the track with
#                      minute ticks, AOS / max / LOS markers and the min elevation mask
#        'azel'      - elevation and azimuth against time for the whole pass
#
# Example:
#   ./scripts/image_processors/polar_plot.py "METEOR-M2 3" ~/raspberry-lrpt/tmp/orbit.tle \
#     1794467850 1794468810 37.98 23.73 15 Southbound /tmp/sky.png direction

import datetime
import sys
from math import degrees

import ephem
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patheffects as pe
import numpy as np
from matplotlib.patches import FancyBboxPatch

# web panel / Passes map palette
BG = '#0a1220'
PANEL = '#07101c'
GRID = '#1c2d44'
RING_TXT = '#5d7390'
TEXT = '#dbe4ee'
DIM = '#8fa3b8'
AOS_C = '#5fd38a'
LOS_C = '#ff6b6b'
SAT_COLOURS = {'METEOR-M2 3': '#f2b33d', 'METEOR-M2 4': '#4fd1c5', 'ISS': '#a78bfa'}
DEFAULT_C = '#9fd3ff'

plt.rcParams.update({
  'font.family': 'DejaVu Sans',
  'font.size': 10,
  'text.color': TEXT,
  'axes.labelcolor': DIM,
  'xtick.color': DIM,
  'ytick.color': DIM,
})


def get_sat(filename, sat_name):
  '''Return the ephem body for sat_name from a 3-line TLE file, or None.'''
  with open(filename) as f:
    lines = [l.strip() for l in f if l.strip()]
  for i in range(0, len(lines) - 2):
    if lines[i] == sat_name and lines[i + 1].startswith('1 ') and lines[i + 2].startswith('2 '):
      return ephem.readtle(lines[i], lines[i + 1], lines[i + 2])
  return None


def track(sat, lat, lon, start, end):
  '''Azimuth/elevation (degrees) and time (epoch s) every second of the pass.'''
  gs = ephem.Observer()
  gs.lat, gs.lon, gs.elevation = str(lat), str(lon), 0
  t, az, el = [], [], []
  for s in range(start, end + 1):
    gs.date = ephem.Date(datetime.datetime.fromtimestamp(s, datetime.timezone.utc).replace(tzinfo=None))
    sat.compute(gs)
    t.append(s)
    az.append(degrees(sat.az))
    el.append(degrees(sat.alt))
  return np.array(t), np.array(az), np.array(el)


def local(ts):
  return datetime.datetime.fromtimestamp(int(ts)).astimezone()


def key_points(t, el, min_el):
  '''Indexes of AOS, max elevation and LOS (first/last sample above min_el).'''
  above = np.where(el >= min_el)[0]
  i_max = int(np.argmax(el))
  if len(above) == 0:
    return None, i_max, None
  return int(above[0]), i_max, int(above[-1])


def new_figure(out_file, width, height):
  '''Figure with the dark card background (rounded corners when saving a PNG).'''
  png = out_file.lower().endswith('.png')
  fig = plt.figure(figsize=(width, height), dpi=120)
  if png:
    fig.patch.set_alpha(0)
    fig.patches.append(FancyBboxPatch((0.004, 0.004), 0.992, 0.992, transform=fig.transFigure,
                                      boxstyle='round,pad=0,rounding_size=0.025',
                                      facecolor=BG, edgecolor='#22344d', linewidth=1.2, zorder=-10))
  else:
    fig.patch.set_facecolor(BG)
  return fig, png


def header(fig, sat_name, colour, kind, t0, max_el, direction, lat, lon, min_el):
  start = local(t0)
  fig.text(0.05, 0.955, sat_name, fontsize=17, fontweight='bold', color=colour, va='top')
  fig.text(0.95, 0.955, kind, fontsize=11, color=DIM, va='top', ha='right')
  fig.text(0.05, 0.905, '{}  ·  {:.0f}° max  ·  {}'.format(
             start.strftime('%a %d/%m/%Y %H:%M %Z'), max_el, direction),
           fontsize=11, color=TEXT, va='top')
  ns = 'N' if float(lat) >= 0 else 'S'
  ew = 'E' if float(lon) >= 0 else 'W'
  fig.text(0.5, 0.025, 'Station {:.3f}°{} {:.3f}°{}  ·  minimum elevation {:.0f}°'.format(
             abs(float(lat)), ns, abs(float(lon)), ew, min_el),
           fontsize=9, color=RING_TXT, ha='center', va='bottom')


def save(fig, out_file, png):
  if png:
    fig.savefig(out_file, facecolor='none')   # keep the rounded card's transparent corners
  else:
    fig.savefig(out_file, facecolor=BG)
  plt.close(fig)


def label_side(azimuth, gap=10):
  '''Offset and alignment that keep a label on the side facing the centre of the sky view.'''
  if np.sin(np.deg2rad(azimuth)) > 0.25:
    return -gap, 'right'
  return gap, 'left'


def glow(colour):
  return [pe.Stroke(linewidth=7, foreground=colour, alpha=0.18), pe.Normal()]


def direction_plot(t, az, el, sat_name, min_el, direction, lat, lon, out_file):
  colour = SAT_COLOURS.get(sat_name, DEFAULT_C)
  aos, imax, los = key_points(t, el, min_el)
  fig, png = new_figure(out_file, 7.2, 8.0)
  header(fig, sat_name, colour, 'Sky track', t[aos if aos is not None else 0], el[imax], direction, lat, lon, min_el)

  ax = fig.add_axes([0.1, 0.09, 0.8, 0.72], projection='polar')
  ax.set_theta_zero_location('N')
  ax.set_theta_direction(-1)
  ax.set_facecolor(PANEL)
  ax.set_ylim(0, 90)                     # radius = 90 - elevation: overhead in the centre
  ax.spines['polar'].set_color('#2a3a50')

  # elevations below the minimum: the "mask" ring at the edge
  ring = np.linspace(0, 2 * np.pi, 361)
  ax.fill_between(ring, 90 - min_el, 90, color='#ffffff', alpha=0.035, linewidth=0)
  ax.plot(np.linspace(0, 2 * np.pi, 361), np.full(361, 90 - min_el), color=RING_TXT,
          linewidth=0.8, linestyle=(0, (4, 4)))

  ax.set_yticks([15, 30, 45, 60, 75])
  ax.set_yticklabels(['75°', '60°', '45°', '30°', '15°'], fontsize=8, color=RING_TXT)
  ax.set_rlabel_position(202.5)
  ax.set_xticks(np.deg2rad(np.arange(0, 360, 45)))
  ax.set_xticklabels(['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'], fontsize=11, color=TEXT)
  ax.tick_params(axis='x', pad=6)
  ax.grid(color=GRID, linewidth=0.8)

  th = np.deg2rad(az)
  r = 90 - el
  up = el >= 0
  ax.plot(np.where(up, th, np.nan), np.where(up, r, np.nan), color=colour, alpha=0.35, linewidth=1.2)
  if aos is not None:
    seg = slice(aos, los + 1)
    ax.plot(th[seg], r[seg], color=colour, linewidth=2.6, path_effects=glow(colour),
            solid_capstyle='round')

    # minute ticks along the usable part of the pass
    for i in range(aos, los + 1):
      if t[i] % 60 == 0:
        ax.plot(th[i], r[i], 'o', color=BG, markeredgecolor=colour, markersize=4.5, zorder=4)
        if t[i] % 120 == 0 and abs(i - aos) > 75 and abs(los - i) > 75 and abs(i - imax) > 45:
          ax.annotate(local(t[i]).strftime('%H:%M'), (th[i], r[i]), xytext=(7, -3),
                      textcoords='offset points', fontsize=8, color=DIM)

    # direction arrow just before the highest point
    j = max(aos, imax - 25)
    ax.annotate('', xy=(th[j + 8], r[j + 8]), xytext=(th[j], r[j]),
                arrowprops=dict(arrowstyle='-|>', color=colour, lw=0, mutation_scale=16))

    for i, c, m, label in ((aos, AOS_C, 'o', 'AOS'), (los, LOS_C, 'o', 'LOS')):
      ax.plot(th[i], r[i], m, color=c, markersize=9, markeredgecolor=BG, markeredgewidth=1.5, zorder=5)
      dx, ha = label_side(az[i])
      ax.annotate('{} {}\naz {:.0f}°'.format(label, local(t[i]).strftime('%H:%M:%S'), az[i]),
                  (th[i], r[i]), xytext=(dx, 4), textcoords='offset points', fontsize=8.5, ha=ha,
                  color=c, fontweight='bold',
                  path_effects=[pe.withStroke(linewidth=3, foreground=PANEL)])

  ax.plot(th[imax], r[imax], '*', color=colour, markersize=16, markeredgecolor=BG, zorder=6)
  dx, ha = label_side(az[imax], 11)
  ax.annotate('{:.0f}°  {}'.format(el[imax], local(t[imax]).strftime('%H:%M')), (th[imax], r[imax]),
              xytext=(dx, -4), textcoords='offset points', ha=ha, fontsize=10, fontweight='bold', color=TEXT,
              path_effects=[pe.withStroke(linewidth=3, foreground=PANEL)])

  save(fig, out_file, png)


def azel_plot(t, az, el, sat_name, min_el, direction, lat, lon, out_file):
  colour = SAT_COLOURS.get(sat_name, DEFAULT_C)
  aos, imax, los = key_points(t, el, min_el)
  fig, png = new_figure(out_file, 8.0, 5.6)
  header(fig, sat_name, colour, 'Elevation & azimuth', t[aos if aos is not None else 0], el[imax],
         direction, lat, lon, min_el)

  mins = (t - t[imax]) / 60.0             # minutes from the highest point
  ax = fig.add_axes([0.09, 0.15, 0.80, 0.64])
  ax.set_facecolor(PANEL)
  for s in ax.spines.values():
    s.set_color('#2a3a50')
  ax.grid(color=GRID, linewidth=0.8)
  ax.set_ylim(0, 90)
  ax.set_yticks(range(0, 91, 15))
  ax.set_xlim(mins[0], mins[-1])
  ax.set_ylabel('Elevation (°)')
  ax.set_xlabel('Minutes from maximum ({})'.format(local(t[imax]).strftime('%H:%M:%S')))

  ax.axhspan(0, min_el, color='#ffffff', alpha=0.035)
  ax.axhline(min_el, color=RING_TXT, linewidth=0.8, linestyle=(0, (4, 4)))
  ax.text(mins[0] + 0.1, min_el + 1.5, 'min {:.0f}°'.format(min_el), fontsize=8, color=RING_TXT)

  elp = np.clip(el, 0, None)
  ax.fill_between(mins, 0, elp, where=el >= min_el, color=colour, alpha=0.18, linewidth=0)
  ax.plot(mins, elp, color=colour, linewidth=2.6, path_effects=glow(colour))

  az2 = ax.twinx()
  az2.set_ylim(0, 360)
  az2.set_yticks(range(0, 361, 90))
  az2.set_yticklabels(['N', 'E', 'S', 'W', 'N'])
  az2.set_ylabel('Azimuth', color=DIM)
  for s in az2.spines.values():
    s.set_visible(False)
  # break the azimuth line where it wraps past north
  azp = az.copy()
  azp[1:][np.abs(np.diff(az)) > 180] = np.nan
  az2.plot(mins, azp, color='#9fd3ff', linewidth=1.2, linestyle=(0, (2, 2)), alpha=0.8)

  if aos is not None:
    for i, c, label in ((aos, AOS_C, 'AOS'), (los, LOS_C, 'LOS')):
      ax.axvline(mins[i], color=c, linewidth=1, alpha=0.6)
      ax.text(mins[i], 87, ' {} {}'.format(label, local(t[i]).strftime('%H:%M:%S')), fontsize=8.5,
              color=c, fontweight='bold', ha='left' if i == aos else 'right', va='top')
  ax.plot(mins[imax], el[imax], '*', color=colour, markersize=15, markeredgecolor=BG, zorder=5)
  ax.annotate('{:.0f}°'.format(el[imax]), (mins[imax], el[imax]), xytext=(0, 9),
              textcoords='offset points', ha='center', fontsize=10, fontweight='bold', color=TEXT)
  if aos is not None:
    fig.text(0.95, 0.905, 'usable {:.1f} min'.format((t[los] - t[aos]) / 60.0), fontsize=11,
             color=DIM, ha='right', va='top')

  save(fig, out_file, png)


def usage():
  print('Usage: polar_plot.py <satellite_name> <tle_file> <pass_start> <pass_end> <latitude> '
        '<longitude> <min_elevation> <direction> <output_file> <azel|direction>')
  sys.exit(1)


def main():
  if len(sys.argv) != 11 or sys.argv[10] not in ('azel', 'direction'):
    usage()
  sat_name, tle_file = sys.argv[1], sys.argv[2]
  start, end = int(sys.argv[3]), int(sys.argv[4])
  lat, lon, min_el = sys.argv[5], sys.argv[6], float(sys.argv[7])
  direction, out_file, plot_type = sys.argv[8], sys.argv[9], sys.argv[10]

  sat = get_sat(tle_file, sat_name)
  if sat is None:
    print('Could not find satellite {} in TLE file {}'.format(sat_name, tle_file))
    sys.exit(1)

  t, az, el = track(sat, lat, lon, start, end)
  if plot_type == 'direction':
    direction_plot(t, az, el, sat_name, min_el, direction, lat, lon, out_file)
  else:
    azel_plot(t, az, el, sat_name, min_el, direction, lat, lon, out_file)


if __name__ == '__main__':
  main()
