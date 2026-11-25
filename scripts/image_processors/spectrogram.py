#!/usr/bin/env python3
#
# Purpose: Record and draw a spectrogram (waterfall) of a Meteor pass.
#
# SatDump live does not keep the radio samples, so there is no recording to analyse afterwards.
# Instead, receive_meteor.sh starts SatDump with its built-in web server and FFT
# (--http_server 127.0.0.1:PORT --fft_enable), and this script polls http://127.0.0.1:PORT/api
# twice a second during the pass. Each answer holds the current spectrum (fft_values, dB, centred
# on the tuned frequency) and the demodulator / decoder state (SNR, frequency offset, Viterbi
# lock, deframer lock). When the pass is over it draws:
#   - the waterfall around the Meteor signal (time down, frequency across)
#   - SNR over time, shaded where the decoder had a lock, with the satellite elevation
#
# Usage:
#   spectrogram.py record <port> <samplerate_hz> <timeout_s> <data.npz> [frequency_mhz]
#   spectrogram.py render <data.npz> <out.png> <sat_name> <tle_file> <lat> <lon> <min_elev>
#   spectrogram.py render-iq <data.npz> <out.png> <sat_name> <tle_file> <lat> <lon> <min_elev> [mode]
#
# "render-iq" draws an ISS pass recorded on its own RTL-SDR by iq_fm.py: the whole band the
# dongle saw (2.38 MHz), the ISS frequency with its expected Doppler track from the TLE, and below
# it the level near the ISS frequency with the elevation.
#
# "record" waits up to 90 s for SatDump's web server, stops when SatDump reports timeout_left 0,
# stops answering, or after timeout + 120 s, and saves what it got.

import datetime
import json
import sys
import time
import urllib.request

import numpy as np

SAT_COLOURS = {'METEOR-M2 3': '#f2b33d', 'METEOR-M2 4': '#4fd1c5', 'ISS': '#a78bfa'}
BG, PANEL, GRID, TEXT, DIM, FAINT = '#0a1220', '#07101c', '#1c2d44', '#dbe4ee', '#8fa3b8', '#5d7390'
LOCK = '#5fd38a'
POLL_S = 0.5             # SatDump's FFT is updated 4 times a second: a row every 0.5 s
SPAN_HZ = 160e3          # show +/-160 kHz around the tuned frequency (LRPT is ~120 kHz wide)

CMAP_STOPS = ['#07101c', '#14284a', '#1f5a8a', '#2fa0a0', '#f2d06b', '#fff6d8']


def colour_lut():
  """256 RGB colours of the waterfall palette (the same as the cards')."""
  stops = np.array([[int(c[i:i + 2], 16) for i in (1, 3, 5)] for c in CMAP_STOPS], dtype=float)
  x = np.linspace(0, 1, 256) * (len(stops) - 1)
  i = np.minimum(x.astype(int), len(stops) - 2)
  f = (x - i)[:, None]
  return (stops[i] * (1 - f) + stops[i + 1] * f).astype(np.uint8)


def pool_cols(a, cols):
  """Max-pool the columns of a down to about `cols`, so a narrow signal survives on a card."""
  k = max(1, a.shape[1] // cols)
  n = a.shape[1] // k * k
  return a[:, :n].reshape(a.shape[0], -1, k).max(axis=2) if k > 1 else a


def full_name(out_file, what):
  """<base>-spectrogram.png -> <base>-spectrogram-<what>.jpg"""
  return (out_file[:-4] if out_file.lower().endswith(('.png', '.jpg')) else out_file) + '-' + what + '.jpg'


def nice_step(span, want):
  """A round tick step (1, 2 or 5 x 10^n) giving about `want` ticks over span."""
  raw = span / max(want, 1)
  p = 10 ** np.floor(np.log10(raw))
  for m in (1, 2, 5, 10):
    if m * p >= raw:
      return m * p
  return 10 * p


def full_waterfall(data, x_vals, x_label, x_fmt, times, out_file, title, colour, marks=(), xscale=1):
  """The waterfall at full resolution: one pixel per frequency point (xscale pixels with
  xscale > 1), one pixel row per spectrum row, newest at the bottom; frequency ticks on top,
  local times on the left, a title line. Written with Pillow (fast at 8192 points wide).
  data: rows x points in dB (NaN = no data, drawn as the background). marks: (x value, label)."""
  from PIL import Image, ImageDraw, ImageFont
  data = np.asarray(data, dtype=np.float32)
  ok = np.isfinite(data)
  lo, hi = (np.percentile(data[ok], 5), np.percentile(data[ok], 99.8)) if ok.any() else (0, 1)
  idx = np.clip((np.nan_to_num(data, nan=lo) - lo) / max(hi - lo, 1e-6) * 255, 0, 255).astype(np.uint8)
  rgb = colour_lut()[idx]
  rgb[~ok] = (7, 16, 28)
  if xscale > 1:
    rgb = np.repeat(rgb, xscale, axis=1)
  h, w = rgb.shape[:2]
  try:
    font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 15)
    bold = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 22)
  except OSError:
    font = bold = ImageFont.load_default()
  left, top, pad = 70, 110, 14
  img = Image.new('RGB', (w + left + pad, h + top + pad), BG)
  img.paste(Image.fromarray(rgb), (left, top))
  dr = ImageDraw.Draw(img)
  dr.text((left, 10), title, fill=colour, font=bold)
  dr.text((left, 40), x_label, fill=DIM, font=font)
  # frequency ticks
  x0, x1 = float(x_vals[0]), float(x_vals[-1])
  step = nice_step(x1 - x0, max(4, w // 180))
  v = np.ceil(x0 / step) * step
  while v <= x1:
    px = left + (v - x0) / (x1 - x0) * (w - 1)
    dr.line([(px, top - 8), (px, top - 1)], fill=DIM, width=1)
    lab = x_fmt(v)
    tw = dr.textlength(lab, font=font)
    dr.text((px - tw / 2, top - 28), lab, fill=TEXT, font=font)
    v += step
  for xv, lab in marks:
    if x0 <= xv <= x1:
      px = left + (xv - x0) / (x1 - x0) * (w - 1)
      for y in range(top, top + h, 12):
        dr.line([(px, y), (px, min(y + 5, top + h))], fill=FAINT, width=1)
      if lab:
        dr.text((px + 4, top - 50), lab, fill=colour, font=font)
  # time ticks: every minute (every 2 or 5 on long images)
  if len(times) > 1:
    t0, t1 = float(times[0]), float(times[-1])
    per = max(1, int(nice_step((t1 - t0) / 60, max(3, h // 120))))
    m = (int(t0 // 60) + 1) * 60
    while m <= t1:
      if (m // 60) % per == 0:
        py = top + (m - t0) / (t1 - t0) * (h - 1)
        dr.line([(left - 8, py), (left - 1, py)], fill=DIM, width=1)
        lab = datetime.datetime.fromtimestamp(m).astimezone().strftime('%H:%M')
        dr.text((6, py - 9), lab, fill=TEXT, font=font)
      m += 60
  img.save(out_file, quality=88, optimize=True)
  return img.size


def poll(url):
  with urllib.request.urlopen(url, timeout=2) as r:
    return json.loads(r.read().decode('utf-8', 'replace'))


def record(port, samplerate, timeout_s, out_file, freq_mhz=137.1):
  url = 'http://127.0.0.1:{}/api'.format(port)
  t_rows, rows, snr, freq, ber, vlock, dlock = [], [], [], [], [], [], []
  started = time.time()
  seen = False
  fails = 0
  frozen = 0
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
    if v and rows and np.array_equal(np.asarray(v, dtype=np.float32), rows[-1]):
      # the same spectrum again: SatDump stopped receiving (the pass is over and it is making
      # the products, its web server still answering with the last values). Not a new row.
      frozen += 1
      if frozen >= 20:
        break
      time.sleep(POLL_S)
      continue
    if v:
      seen = True
      frozen = 0
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
    time.sleep(POLL_S)

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
  # spectra repeated at the end (SatDump done receiving, still answering) are not signal
  n = len(fft)
  while n > 1 and np.array_equal(fft[n - 1], fft[n - 2]):
    n -= 1
  t, fft, snr, dlock, vlock = t[:n], fft[:n], snr[:n], dlock[:n], vlock[:n]
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

  # the full-resolution waterfall next to the card (<base>-spectrogram-full.jpg)
  try:
    full_waterfall(wf, f_khz, 'Offset from {:.4f} MHz (kHz)  ·  {:.0f} Hz a point  ·  a row every {:.1f} s'.format(
                   fmhz, fs / nbin, float(np.median(np.diff(t))) if len(t) > 1 else 1), lambda v: '{:+g}'.format(v),
                   t, full_name(out_file, 'full'), '{}  ·  {}'.format(sat_name, start.strftime('%d/%m/%Y %H:%M')),
                   colour, marks=[(0, '')], xscale=max(1, 1200 // len(f_khz)))
  except Exception as e:
    print('Full-resolution spectrogram not written: %s' % e)

  png = out_file.lower().endswith('.png')
  fig = plt.figure(figsize=(6.4, 9.0), dpi=160)
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
  ax.imshow(pool_cols(wf, 800), aspect='auto', cmap=cmap, vmin=lo, vmax=hi, interpolation='antialiased',
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
  write_stats(data_file, t, snr, dlock, el, min_elev)
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


def doppler(tle_file, sat_name, lat, lon, times, freq_hz):
  """Expected Doppler shift (Hz) of freq_hz for each time, from the TLE (None when unknown)."""
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
      out.append(-float(sat.range_velocity) / 299792458.0 * freq_hz)
    return np.array(out)
  except Exception:
    return None


def render_iq(data_file, out_file, sat_name, tle_file, lat, lon, min_elev, mode=''):
  import matplotlib
  matplotlib.use('Agg')
  import matplotlib.pyplot as plt
  import matplotlib.dates as mdates
  from matplotlib.colors import LinearSegmentedColormap
  from matplotlib.patches import FancyBboxPatch

  plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 9, 'text.color': TEXT,
                       'axes.labelcolor': DIM, 'xtick.color': DIM, 'ytick.color': DIM})
  d = np.load(data_file)
  t, fft = d['t'], d['fft'].astype(np.float32)
  rate, center, target = float(d['rate']), float(d['center_hz']), float(d['target_hz'])
  nbin = fft.shape[1]
  f_mhz = (center + (np.arange(nbin) - nbin / 2) * rate / nbin) / 1e6
  # the dongle's DC spike in the middle (a few points wide at 8192): take its neighbours' level
  mid, w = nbin // 2, max(1, nbin // 2048)
  for k in range(mid - w, mid + w + 1):
    fft[:, k] = (fft[:, mid - w - 1] + fft[:, mid + w + 1]) / 2
  lo, hi = np.percentile(fft, 5), np.percentile(fft, 99.8)
  colour = SAT_COLOURS.get(sat_name, '#9fd3ff')

  local = [datetime.datetime.fromtimestamp(x).astimezone() for x in t]
  start, end = local[0], local[-1]
  tz = start.tzinfo
  dop = doppler(tle_file, sat_name, lat, lon, t, target)
  el = elevation(tle_file, sat_name, lat, lon, t)

  # level near the ISS frequency (its Doppler track +/-12 kHz) above the band's median
  floor = np.median(fft, axis=1)
  track = target + (dop if dop is not None else np.zeros(len(t)))
  level = []
  for i, f in enumerate(track):
    k = np.abs(f_mhz * 1e6 - f) <= 12e3
    level.append(float(fft[i, k].max() - floor[i]) if k.any() else 0.0)
  level = np.array(level)

  # full resolution: the whole band, and the ISS channel with the Doppler shift taken out
  label = '{}  ·  {}{}'.format(sat_name, start.strftime('%d/%m/%Y %H:%M'), '  ·  ' + mode if mode else '')
  try:
    full_waterfall(fft, f_mhz, 'Frequency (MHz)  ·  {:.0f} Hz a point  ·  a row every {:.1f} s'.format(
                   rate / nbin, float(np.median(np.diff(t))) if len(t) > 1 else 1), lambda v: '{:.2f}'.format(v),
                   t, full_name(out_file, 'full'), label + '  ·  whole band', colour,
                   marks=[(target / 1e6, '{:.3f}'.format(target / 1e6))])
  except Exception as e:
    print('Full-resolution spectrogram not written: %s' % e)
  if 'zoom' in d.files and len(d['zt']) > 1:
    try:
      channel_waterfall(d, tle_file, sat_name, lat, lon, target, full_name(out_file, 'channel'), label, colour)
    except Exception as e:
      print('Channel spectrogram not written: %s' % e)

  png = out_file.lower().endswith('.png')
  fig = plt.figure(figsize=(6.4, 9.0), dpi=160)
  if png:
    fig.patch.set_alpha(0)
    fig.patches.append(FancyBboxPatch((0.004, 0.003), 0.992, 0.994, transform=fig.transFigure,
                                      boxstyle='round,pad=0,rounding_size=0.02',
                                      facecolor=BG, edgecolor='#22344d', linewidth=1.2, zorder=-10))
  else:
    fig.patch.set_facecolor(BG)
  fig.text(0.06, 0.972, sat_name, fontsize=15, fontweight='bold', color=colour, va='top')
  fig.text(0.94, 0.972, 'Spectrogram' + (' · ' + mode if mode else ''), fontsize=10, color=DIM,
           va='top', ha='right')
  fig.text(0.06, 0.937, '{}  ·  {}–{}  ·  {:.3f} MHz'.format(start.strftime('%a %d/%m/%Y'),
           start.strftime('%H:%M'), end.strftime('%H:%M %Z'), target / 1e6), fontsize=10, color=TEXT, va='top')
  fig.text(0.06, 0.910, 'whole band {:.2f}–{:.2f} MHz ({:.2f} MS/s)  ·  peak {:.0f} dB over the floor'.format(
           f_mhz[0], f_mhz[-1], rate / 1e6, float(level.max()) if len(level) else 0), fontsize=9.5,
           color=DIM, va='top')

  ax = fig.add_axes([0.13, 0.36, 0.80, 0.52])
  ax.set_facecolor(PANEL)
  cmap = LinearSegmentedColormap.from_list('rl1', ['#07101c', '#14284a', '#1f5a8a', '#2fa0a0',
                                                   '#f2d06b', '#fff6d8'])
  tnum = mdates.date2num(local)
  ax.imshow(pool_cols(fft, 1000), aspect='auto', cmap=cmap, vmin=lo, vmax=hi, interpolation='antialiased',
            extent=[f_mhz[0], f_mhz[-1], tnum[-1], tnum[0]])
  ax.yaxis_date(tz)
  ax.yaxis.set_major_formatter(mdates.DateFormatter('%H:%M', tz=tz))
  ax.set_xlabel('Frequency (MHz)')
  for sp in ax.spines.values():
    sp.set_color('#2a3a50')
  ax.axvline(target / 1e6, color=FAINT, linewidth=0.6, linestyle=(0, (3, 4)))
  if dop is not None:
    ax.plot(track / 1e6 + 0.03, tnum, color=colour, linewidth=0.9, alpha=0.7, linestyle=(0, (2, 3)))

  bx = fig.add_axes([0.13, 0.065, 0.80, 0.175])
  bx.set_facecolor(PANEL)
  for sp in bx.spines.values():
    sp.set_color('#2a3a50')
  bx.grid(color=GRID, linewidth=0.7)
  bx.plot(local, level, color=colour, linewidth=1.4)
  bx.set_ylabel('Level (dB)')
  bx.set_ylim(0, max(10, float(level.max()) * 1.15 if len(level) else 10))
  bx.set_xlim(local[0], local[-1])
  bx.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M', tz=tz))
  if el is not None:
    ex = bx.twinx()
    ex.plot(local, el, color='#9fd3ff', linewidth=1, linestyle=(0, (2, 2)), alpha=0.8)
    ex.axhline(min_elev, color=FAINT, linewidth=0.6, linestyle=(0, (3, 4)))
    ex.set_ylim(0, 90)
    ex.set_yticks([0, 30, 60, 90])
    ex.set_ylabel('Elevation (°)', color=DIM)
    for sp in ex.spines.values():
      sp.set_visible(False)
  fig.text(0.13, 0.268, '—', color=colour, fontsize=10, va='center', fontweight='bold')
  fig.text(0.16, 0.268, 'level at the ISS frequency (Doppler-corrected)   ', color=DIM, fontsize=8.5, va='center')
  if dop is not None:
    fig.text(0.13, 0.292, '- -', color=colour, fontsize=9, va='center')
    fig.text(0.175, 0.292, 'expected Doppler track (drawn just right of the signal)', color=DIM,
             fontsize=8.5, va='center')
  if el is not None:
    fig.text(0.70, 0.268, '- -', color='#9fd3ff', fontsize=9, va='center')
    fig.text(0.745, 0.268, 'elevation', color=DIM, fontsize=8.5, va='center')
  fig.savefig(out_file, facecolor='none' if png else BG)
  plt.close(fig)


CHANNEL_SPAN = 12e3      # the channel picture: +/-12 kHz around the ISS frequency after the Doppler


def channel_waterfall(d, tle_file, sat_name, lat, lon, target, out_file, label, colour):
  """The ISS channel (iq_fm.py's zoom rows, 43 Hz a point, a row every 0.2 s) with the expected
  Doppler shift from the TLE taken out, so the ISS's signal runs straight down the middle:
  +/-CHANNEL_SPAN, each point drawn 2 pixels wide."""
  zt, zoom = d['zt'], d['zoom'].astype(np.float32)
  zr = float(d['zoom_rate']) if 'zoom_rate' in d.files else 44100.0
  n = zoom.shape[1]
  f = (np.arange(n) - n / 2) * zr / n                      # offset from the ISS frequency (Hz)
  # the middle point is the ISS frequency itself (not the dongle's DC): nothing to patch
  dop = doppler(tle_file, sat_name, lat, lon, zt, target)
  if dop is None:
    dop = np.zeros(len(zt))
  step = zr / n
  grid = np.arange(-CHANNEL_SPAN, CHANNEL_SPAN + step / 2, step)
  # a point is valid only inside the channel filter's pass band (+/-19.8 kHz)
  out = np.full((len(zt), len(grid)), np.nan, np.float32)
  for i in range(len(zt)):
    src = grid + dop[i]
    ok = np.abs(src) <= 0.9 * zr / 2
    out[i, ok] = np.interp(src[ok], f, zoom[i])
  full_waterfall(out, grid / 1e3, 'Offset from the ISS frequency {:.3f} MHz after the expected Doppler (kHz)'
                 '  ·  {:.0f} Hz a point  ·  a row every {:.1f} s'.format(target / 1e6, step,
                 float(np.median(np.diff(zt)))), lambda v: '{:+g}'.format(v), zt, out_file,
                 label + '  ·  ISS channel', colour, marks=[(0, '')], xscale=2)


def write_stats(data_file, t, snr, dlock, el, min_elev):
  """The pass's numbers for the web panel, next to the data file (<data>.json): seconds recorded,
  seconds the decoder was locked, peak SNR, mean SNR while locked, and the quality: the share of
  the time the satellite was above the minimum elevation that the decoder was locked (0-100).
  A QFH typically keeps lock for most of a good pass above 15°; 0 means nothing was decoded."""
  import json
  try:
    n = len(t)
    if n < 2:
      return
    dt = float(np.median(np.diff(t))) or 1.0
    locked = dlock > 0
    snr = np.nan_to_num(np.asarray(snr, dtype=float))
    stats = {
      'seconds': int(round(n * dt)),
      'locked_s': int(round(locked.sum() * dt)),
      'snr_peak': round(float(snr.max()), 1),
      'snr_avg': round(float(snr[locked].mean()), 1) if locked.any() else 0.0,
    }
    if el is not None:
      up = np.asarray(el) >= float(min_elev)
      stats['quality'] = int(round(100.0 * (locked & up).sum() / up.sum())) if up.any() else None
    if stats.get('quality') is None:
      stats['quality'] = int(round(100.0 * locked.mean()))
    with open(data_file[:-4] + '.json' if data_file.endswith('.npz') else data_file + '.json', 'w') as f:
      json.dump(stats, f)
  except Exception as e:                                # the picture matters more
    print('Pass statistics not written: %s' % e)


def main():
  a = sys.argv
  if len(a) in (6, 7) and a[1] == 'record':
    record(int(a[2]), float(a[3]), float(a[4]), a[5], float(a[6]) if len(a) == 7 else 137.1)
  elif len(a) == 9 and a[1] == 'render':
    render(a[2], a[3], a[4], a[5], a[6], a[7], float(a[8]))
  elif len(a) in (9, 10) and a[1] == 'render-iq':
    render_iq(a[2], a[3], a[4], a[5], a[6], a[7], float(a[8]), a[9] if len(a) == 10 else '')
  else:
    print(__doc__ if __doc__ else 'see the header of this file for usage')
    print('usage: spectrogram.py record <port> <samplerate_hz> <timeout_s> <data.npz> [frequency_mhz]')
    print('       spectrogram.py render <data.npz> <out.png> <sat_name> <tle_file> <lat> <lon> <min_elev>')
    sys.exit(1)


if __name__ == '__main__':
  main()
