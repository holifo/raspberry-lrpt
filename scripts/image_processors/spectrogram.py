#!/usr/bin/env python3
#
# Purpose: Record and draw a spectrogram (waterfall) of a Meteor pass.
#
# SatDump live does not keep the radio samples, so there is no recording to analyse afterwards.
# Instead, receive_meteor.sh starts SatDump with its built-in web server and FFT
# (--http_server 127.0.0.1:PORT --fft_enable), and this script polls http://127.0.0.1:PORT/api
# once a second during the pass. Each answer holds the current spectrum (fft_values, dB, centred
# on the tuned frequency) and the demodulator / decoder state (SNR, frequency offset, Viterbi
# lock, deframer lock). When the pass is over it draws:
#   - the waterfall around the Meteor signal (time down, frequency across)
#   - SNR over time, shaded where the decoder had a lock, with the satellite elevation
#
# Usage:
#   spectrogram.py record <port> <samplerate_hz> <timeout_s> <data.npz> [frequency_mhz]
#   spectrogram.py render <data.npz> <out.png> <sat_name> <tle_file> <lat> <lon> <min_elev>
#
# "record" waits up to 90 s for SatDump's web server, stops when SatDump reports timeout_left 0,
# stops answering, or after timeout + 120 s, and saves what it got.

import datetime
import json
import sys
import time
import urllib.request

import numpy as np

SAT_COLOURS = {'METEOR-M2 3': '#f2b33d', 'METEOR-M2 4': '#4fd1c5'}
BG, PANEL, GRID, TEXT, DIM, FAINT = '#0a1220', '#07101c', '#1c2d44', '#dbe4ee', '#8fa3b8', '#5d7390'
LOCK = '#5fd38a'
SPAN_HZ = 160e3          # show +/-160 kHz around the tuned frequency (LRPT is ~120 kHz wide)


def poll(url):
  with urllib.request.urlopen(url, timeout=2) as r:
    return json.loads(r.read().decode('utf-8', 'replace'))


def record(port, samplerate, timeout_s, out_file, freq_mhz=137.1):
  url = 'http://127.0.0.1:{}/api'.format(port)
  t_rows, rows, snr, freq, ber, vlock, dlock = [], [], [], [], [], [], []
  started = time.time()
  seen = False
  fails = 0
  while time.time() - started < timeout_s + 120:
    try:
      d = poll(url)
      fails = 0
    except Exception:
      fails += 1
      if (seen and fails >= 5) or (not seen and time.time() - started > 90):
        break
      time.sleep(1)
      continue
    v = d.get('fft_values')
    if v:
      seen = True
      demod = d.get('psk_demod', {})
      dec = d.get('ccsds_conv_concat_decoder', {})
      t_rows.append(time.time())
      rows.append(np.asarray(v, dtype=np.float32))
      snr.append(float(demod.get('snr', np.nan)))
      freq.append(float(demod.get('freq', np.nan)))
      ber.append(float(dec.get('viterbi_ber', np.nan)))
      vlock.append(1 if dec.get('viterbi_lock') in (1, True, '1') else 0)
      dlock.append(1 if dec.get('deframer_lock') in (1, True, 'true') else 0)
    if d.get('timeout_left') is not None and float(d['timeout_left']) <= 0:
      break
    time.sleep(1)

  if not rows:
    print('No spectrum received from SatDump on port {}'.format(port))
    sys.exit(1)
  n = min(len(r) for r in rows)
  np.savez_compressed(out_file, t=np.array(t_rows), fft=np.stack([r[:n] for r in rows]),
                      snr=np.array(snr), freq=np.array(freq), ber=np.array(ber),
                      vlock=np.array(vlock), dlock=np.array(dlock), samplerate=float(samplerate),
                      frequency_mhz=float(freq_mhz))
  print('Recorded {} spectra of {} bins'.format(len(rows), n))


def elevation(tle_file, sat_name, lat, lon, times):
  try:
    import ephem
    lines = [l.strip() for l in open(tle_file) if l.strip()]
    i = lines.index(sat_name)
    sat = ephem.readtle(lines[i], lines[i + 1], lines[i + 2])
    gs = ephem.Observer()
    gs.lat, gs.lon, gs.elevation = str(lat), str(lon), 0
    out = []
    for t in times:
      gs.date = ephem.Date(datetime.datetime.fromtimestamp(t, datetime.timezone.utc).replace(tzinfo=None))
      sat.compute(gs)
      out.append(np.degrees(float(sat.alt)))
    return np.array(out)
  except Exception:
    return None


def runs(mask):
  '''(start, end) index pairs where mask is true'''
  out, start = [], None
  for i, m in enumerate(list(mask) + [False]):
    if m and start is None:
      start = i
    elif not m and start is not None:
      out.append((start, i - 1))
      start = None
  return out


def render(data_file, out_file, sat_name, tle_file, lat, lon, min_elev):
  import matplotlib
  matplotlib.use('Agg')
  import matplotlib.pyplot as plt
  import matplotlib.dates as mdates
  from matplotlib.colors import LinearSegmentedColormap
  from matplotlib.patches import FancyBboxPatch

  plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 9, 'text.color': TEXT,
                       'axes.labelcolor': DIM, 'xtick.color': DIM, 'ytick.color': DIM})
  d = np.load(data_file)
  t, fft, snr, dlock, vlock = d['t'], d['fft'], d['snr'], d['dlock'], d['vlock']
  # the first spectra after SatDump starts are not settled yet (far too strong): drop them
  med = np.median(fft, axis=1)
  good = med < np.median(med) + 6
  first = int(np.argmax(good)) if good.any() else 0
  t, fft, snr, dlock, vlock = t[first:], fft[first:], snr[first:], dlock[first:], vlock[first:]
  fs = float(d['samplerate'])
  fmhz = float(d['frequency_mhz']) if 'frequency_mhz' in d.files else 137.1
  nbin = fft.shape[1]
  colour = SAT_COLOURS.get(sat_name, '#9fd3ff')

  # frequency of each bin (the FFT is centred on the tuned frequency); keep +/- SPAN_HZ
  f_khz = (np.arange(nbin) - nbin / 2) * fs / nbin / 1e3
  keep = np.abs(f_khz) <= SPAN_HZ / 1e3
  wf = fft[:, keep]
  f_khz = f_khz[keep]
  lo, hi = np.percentile(wf, 5), np.percentile(wf, 99.7)

  local = [datetime.datetime.fromtimestamp(x).astimezone() for x in t]
  start, end = local[0], local[-1]
  tz = start.tzinfo

  png = out_file.lower().endswith('.png')
  fig = plt.figure(figsize=(6.4, 9.0), dpi=120)
  if png:
    fig.patch.set_alpha(0)
    fig.patches.append(FancyBboxPatch((0.004, 0.003), 0.992, 0.994, transform=fig.transFigure,
                                      boxstyle='round,pad=0,rounding_size=0.02',
                                      facecolor=BG, edgecolor='#22344d', linewidth=1.2, zorder=-10))
  else:
    fig.patch.set_facecolor(BG)

  locked = int(dlock.sum())
  fig.text(0.06, 0.972, sat_name, fontsize=15, fontweight='bold', color=colour, va='top')
  fig.text(0.94, 0.972, 'Spectrogram', fontsize=10, color=DIM, va='top', ha='right')
  fig.text(0.06, 0.937, '{}  ·  {}–{}  ·  {:.1f} MHz'.format(start.strftime('%a %d/%m/%Y'),
           start.strftime('%H:%M'), end.strftime('%H:%M %Z'), fmhz), fontsize=10, color=TEXT, va='top')
  fig.text(0.06, 0.910, 'peak SNR {:.1f} dB  ·  decoder locked {:d} min {:02d} s'.format(
           np.nanmax(snr) if len(snr) else 0, locked // 60, locked % 60), fontsize=9.5, color=DIM, va='top')

  # waterfall
  ax = fig.add_axes([0.13, 0.36, 0.80, 0.52])
  ax.set_facecolor(PANEL)
  cmap = LinearSegmentedColormap.from_list('rl1', ['#07101c', '#14284a', '#1f5a8a', '#2fa0a0',
                                                   '#f2d06b', '#fff6d8'])
  tnum = mdates.date2num(local)
  ax.imshow(wf, aspect='auto', cmap=cmap, vmin=lo, vmax=hi, interpolation='nearest',
            extent=[f_khz[0], f_khz[-1], tnum[-1], tnum[0]])
  ax.yaxis_date(tz)
  ax.yaxis.set_major_formatter(mdates.DateFormatter('%H:%M', tz=tz))
  ax.set_xlabel('Offset from {:.1f} MHz (kHz)'.format(fmhz))
  for s in ax.spines.values():
    s.set_color('#2a3a50')
  ax.axvline(0, color=FAINT, linewidth=0.6, linestyle=(0, (3, 4)))

  # SNR with the lock periods, and the satellite elevation
  bx = fig.add_axes([0.13, 0.065, 0.80, 0.175])
  bx.set_facecolor(PANEL)
  for s in bx.spines.values():
    s.set_color('#2a3a50')
  bx.grid(color=GRID, linewidth=0.7)
  for a, b in runs(dlock > 0):
    bx.axvspan(local[a], local[b], color=LOCK, alpha=0.12, linewidth=0)
  bx.plot(local, snr, color=colour, linewidth=1.6)
  bx.set_ylabel('SNR (dB)')
  bx.set_ylim(0, max(10, np.nanmax(snr) * 1.15 if len(snr) else 10))
  bx.set_xlim(local[0], local[-1])
  bx.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M', tz=tz))
  el = elevation(tle_file, sat_name, lat, lon, t)
  if el is not None:
    ex = bx.twinx()
    ex.plot(local, el, color='#9fd3ff', linewidth=1, linestyle=(0, (2, 2)), alpha=0.8)
    ex.axhline(min_elev, color=FAINT, linewidth=0.6, linestyle=(0, (3, 4)))
    ex.set_ylim(0, 90)
    ex.set_yticks([0, 30, 60, 90])
    ex.set_ylabel('Elevation (°)', color=DIM)
    for s in ex.spines.values():
      s.set_visible(False)
  fig.text(0.13, 0.268, '■', color=LOCK, alpha=0.5, fontsize=9, va='center')
  fig.text(0.155, 0.268, 'decoder locked   ', color=DIM, fontsize=8.5, va='center')
  fig.text(0.40, 0.268, '—', color=colour, fontsize=10, va='center', fontweight='bold')
  fig.text(0.43, 0.268, 'SNR   ', color=DIM, fontsize=8.5, va='center')
  if el is not None:
    fig.text(0.53, 0.268, '- -', color='#9fd3ff', fontsize=9, va='center')
    fig.text(0.575, 0.268, 'elevation', color=DIM, fontsize=8.5, va='center')

  if png:
    fig.savefig(out_file, facecolor='none')
  else:
    fig.savefig(out_file, facecolor=BG)
  plt.close(fig)


def main():
  a = sys.argv
  if len(a) in (6, 7) and a[1] == 'record':
    record(int(a[2]), float(a[3]), float(a[4]), a[5], float(a[6]) if len(a) == 7 else 137.1)
  elif len(a) == 9 and a[1] == 'render':
    render(a[2], a[3], a[4], a[5], a[6], a[7], float(a[8]))
  else:
    print(__doc__ if __doc__ else 'see the header of this file for usage')
    print('usage: spectrogram.py record <port> <samplerate_hz> <timeout_s> <data.npz> [frequency_mhz]')
    print('       spectrogram.py render <data.npz> <out.png> <sat_name> <tle_file> <lat> <lon> <min_elev>')
    sys.exit(1)


if __name__ == '__main__':
  main()
