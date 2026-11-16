#!/usr/bin/env python3
"""Decode the SSTV images in an FM recording of an ISS pass (145.800 MHz, ARISS events).

    sstv_decode.py AUDIO OUT_PREFIX [--rate HZ] [--min-rows 0.25]

AUDIO is a WAV file, or raw signed 16-bit mono samples (rtl_fm's output) at --rate Hz.
Writes OUT_PREFIX-1.png, OUT_PREFIX-2.png, ... and prints one JSON line per image
({"file", "mode", "rows", "complete", "sync"}).

The ISS sends PD120 (sometimes PD180 or PD90). PD modes are decoded here from the line
sync pulses rather than the VIS start code: every pair of lines starts with a 20 ms
1200 Hz pulse, so the decoder finds those pulses, fits a straight line through their
times (that takes out the slant from the receiver's clock error) and reads the pixels
between them. This copes with noise, a pass that starts or ends in the middle of an
image, and a missed start code - the usual state of a recording from a satellite.
Other modes (Robot, Martin, Scottie, ...) go to the `sstv` package when it is installed;
it needs their start code.
"""
import argparse
import json
import sys
import wave

import numpy as np
from PIL import Image

# PD modes: name -> (width, height, pixel time in ms). Line pair = sync 20 ms, porch 2.08 ms,
# then Y (even line), R-Y, B-Y, Y (odd line), each width * pixel time.
PD_MODES = {
    'PD50': (320, 256, 0.286),
    'PD90': (320, 256, 0.532),
    'PD120': (640, 496, 0.190),
    'PD160': (512, 400, 0.382),
    'PD180': (640, 496, 0.286),
    'PD240': (640, 496, 0.382),
    'PD290': (800, 616, 0.286),
}
SYNC_MS, PORCH_MS = 20.0, 2.08


def pair_ms(mode):
    w, _, px = PD_MODES[mode]
    return SYNC_MS + PORCH_MS + 4 * w * px


def load(path, rate):
    try:
        with wave.open(path, 'rb') as w:
            rate = w.getframerate()
            ch, width = w.getnchannels(), w.getsampwidth()
            raw = w.readframes(w.getnframes())
        if width != 2:
            raise SystemExit('only 16-bit WAV files are supported')
        x = np.frombuffer(raw, dtype='<i2')[::ch]
    except wave.Error:
        x = np.fromfile(path, dtype='<i2')
    return x.astype(np.float32) / 32768.0, rate


def lowpass(x, rate, cutoff, taps=None):
    taps = taps or (int(rate / cutoff * 4) | 1)
    n = np.arange(taps) - taps // 2
    h = np.sinc(2 * cutoff / rate * n) * np.hamming(taps)
    h /= h.sum()
    return np.convolve(x, h, mode='same')


def frequency_track(x, rate, chunk=1 << 20):
    """Instantaneous frequency (Hz) of the audio, for tones between about 1000 and 2500 Hz."""
    out = np.empty(len(x), dtype=np.float32)
    pad = 256
    for start in range(0, len(x), chunk):
        a, b = max(0, start - pad), min(len(x), start + chunk + pad)
        t = np.arange(a, b) / rate
        z = x[a:b] * np.exp(-2j * np.pi * 1900.0 * t)          # 1900 Hz to 0 Hz
        z = lowpass(z.real, rate, 900) + 1j * lowpass(z.imag, rate, 900)
        f = np.angle(z[1:] * np.conj(z[:-1])) * rate / (2 * np.pi) + 1900.0
        f = np.concatenate([[f[0]], f])
        out[start:min(len(x), start + chunk)] = f[start - a:start - a + min(chunk, len(x) - start)]
    return out


def find_syncs(f, rate):
    """Times (s) where a 20 ms 1200 Hz sync pulse starts. A matched filter: the share of
    samples in the sync band over 20 ms peaks near 1 on a pulse, and noise only lowers it."""
    k = int(rate * SYNC_MS / 1000)
    ind = np.convolve(((f > 1050) & (f < 1350)).astype(np.float32), np.ones(k) / k, mode='same')
    cand = np.where((ind > 0.5) & (ind >= np.roll(ind, 1)) & (ind > np.roll(ind, -1)))[0]
    peaks, last = [], -10 ** 9
    min_sep = int(rate * 0.15)                  # shorter than any PD line pair
    for i in cand:                              # strongest peak in each 150 ms
        if i - last < min_sep:
            if ind[i] > ind[peaks[-1]]:
                peaks[-1] = i
                last = i
            continue
        peaks.append(i)
        last = i
    return (np.array(peaks) - k // 2) / rate


def best_mode(times):
    """The PD mode whose line-pair period best explains the spacing of the sync pulses."""
    if len(times) < 8:
        return None, 0
    best, best_n = None, 0
    for mode in PD_MODES:
        p = pair_ms(mode) / 1000
        n = 0
        for i in range(len(times) - 1):         # pulses whose next pulse is 1..4 pairs on
            d = times[i + 1:i + 6] - times[i]
            k = np.round(d / p)
            n += int(((k >= 1) & (k <= 4) & (np.abs(d - k * p) < 0.004)).any())
        if n > best_n:
            best, best_n = mode, n
    return (best, best_n) if best_n >= 8 else (None, 0)


def fit_runs(times, period, image_gap=15.0, min_pulses=8, tol=0.004):
    """Split the pulses into transmissions (a pause of image_gap s between them) and fit
    t = t0 + P * i to each with RANSAC: noise adds stray pulses and loses real ones."""
    runs, cur = [], [times[0]]
    for t in times[1:]:
        if t - cur[-1] > image_gap:
            runs.append(cur)
            cur = [t]
        else:
            cur.append(t)
    runs.append(cur)
    rng = np.random.default_rng(1)
    fits = []
    for r in runs:
        r = np.array(r)
        if len(r) < min_pulses:
            continue
        best = None
        for _ in range(300):
            i, j = sorted(rng.choice(len(r), 2, replace=False))
            k = round((r[j] - r[i]) / period)
            if k < 1:
                continue
            p = (r[j] - r[i]) / k
            if abs(p / period - 1) > 0.01:     # receiver clock within 1%
                continue
            idx = np.round((r - r[i]) / p)
            inl = np.abs(r - (r[i] + idx * p)) < tol
            if best is None or inl.sum() > best[0]:
                best = (inl.sum(), inl, r[i], p)
        if best is None or best[0] < min_pulses:
            continue
        _, inl, t_ref, p = best
        idx = np.round((r[inl] - t_ref) / p)
        p, b = np.polyfit(idx, r[inl], 1)
        lo, hi = int(idx.min()), int(idx.max())
        fits.append({'t0': b + lo * p, 'period': p, 'n': hi - lo + 1, 'good': int(inl.sum())})
    return fits


def ycc_to_rgb(y, cr, cb):
    y, cr, cb = (np.asarray(v, np.float32) for v in (y, cr, cb))
    r = y + 1.402 * (cr - 128)
    g = y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)
    b = y + 1.772 * (cb - 128)
    return np.clip(np.stack([r, g, b], -1), 0, 255).astype(np.uint8)


def decode_pd(f, rate, mode, fit, vis_before):
    w, h, px = PD_MODES[mode]
    pairs = h // 2
    period = fit['period']
    scale = period / (pair_ms(mode) / 1000)     # the recording's clock vs the mode's
    px_s = px / 1000 * scale
    fs = lowpass(f, rate, 1 / (2 * px_s) if 1 / (2 * px_s) < rate / 2.2 else rate / 2.2)
    n = min(fit['n'], pairs)
    # where the received pairs go in the picture: from the top after a start code, else from
    # the bottom when the transmission plainly ended (a pass that began mid-image), else the top
    first = 0
    if not vis_before and fit['n'] < pairs and fit.get('ended'):
        first = pairs - n
    img = np.zeros((h, w, 3), np.uint8)
    seg = w * px_s
    pix = (np.arange(w) + 0.5) * px_s
    for i in range(n):
        t = fit['t0'] + i * period + (SYNC_MS + PORCH_MS) / 1000 * scale
        def read(k):
            s = (t + k * seg + pix) * rate
            v = np.interp(s, np.arange(len(fs)), fs)
            return np.clip((v - 1500) / 800 * 255, 0, 255)
        y0, cr, cb, y1 = read(0), read(1), read(2), read(3)
        row = 2 * (first + i)
        img[row] = ycc_to_rgb(y0, cr, cb)
        img[row + 1] = ycc_to_rgb(y1, cr, cb)
    return Image.fromarray(img), n, pairs, first


def vis_near(f, rate, t, window=1.0):
    """True when a VIS leader (300 ms of 1900 Hz) ends within `window` s before t."""
    a = max(0, int((t - window - 0.35) * rate))
    b = int(t * rate)
    seg = f[a:b]
    if len(seg) < 0.3 * rate:
        return False
    k = int(0.25 * rate)
    run = np.convolve(((seg > 1800) & (seg < 2000)).astype(np.float32), np.ones(k) / k, mode='valid')
    return bool((run > 0.85).any())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('audio')
    ap.add_argument('out_prefix')
    ap.add_argument('--rate', type=int, default=11025)
    ap.add_argument('--min-rows', type=float, default=0.25, help='smallest share of an image to keep')
    args = ap.parse_args()

    x, rate = load(args.audio, args.rate)
    if len(x) < rate * 10:
        return
    x = x - lowpass(x, rate, 300)             # FM's DC offset (Doppler) and hum
    f = frequency_track(x, rate)
    starts = find_syncs(f, rate)
    results = []
    mode, n_ok = best_mode(starts)
    if mode:
        for fit in fit_runs(starts, pair_ms(mode) / 1000):
            fit['ended'] = fit['t0'] + fit['n'] * fit['period'] < len(x) / rate - 2 * fit['period']
            img, n, pairs, first = decode_pd(f, rate, mode, fit, vis_near(f, rate, fit['t0']))
            if n / pairs < args.min_rows:
                continue
            results.append((img, mode, n * 2, n >= pairs - 2, round(fit['good'] / max(1, fit['n']), 2)))
    if not results:                            # not PD: other modes, from their start code
        try:
            import sstv
            for img in sstv.decode((x * 32767).astype(np.int16), rate):
                m = str(img.info.get('sstv_mode', '')).replace('Mode.', '')
                results.append((img.convert('RGB'), m, img.size[1], bool(img.info.get('sstv_complete')), None))
        except ImportError:
            pass
    for i, (img, m, rows, complete, sync) in enumerate(results, 1):
        name = f'{args.out_prefix}-{i}.png'
        img.save(name)
        print(json.dumps({'file': name, 'mode': m, 'rows': rows, 'complete': complete, 'sync': sync}))


if __name__ == '__main__':
    sys.exit(main())
