#!/usr/bin/env python3
#
# Purpose: an ISS pass on the ISS's own RTL-SDR (two dongles): record the whole 2.38 MHz the
#          dongle sees, keep a spectrum of it once a second for the pass's spectrogram, and FM
#          demodulate the ISS frequency on the way, like rtl_fm did.
#
#   rtl_sdr -s 2381400 -f <ISS MHz - 264.6 kHz> ... - | iq_fm.py OUT.npz CENTER_HZ TARGET_HZ > audio
#
# stdin   unsigned 8-bit I/Q from rtl_sdr at RATE (2 381 400 S/s = 108 x 22 050: the decimation
#         steps are whole numbers, and the ISS frequency sits OFFSET (264.6 kHz = RATE / 9) above
#         the tuned centre, away from the dongle's DC spike, so the mixer is a 9-sample table)
# stdout  FM audio, signed 16-bit mono at 22 050 Hz, scaled like rtl_fm's (direwolf and
#         sstv_decode.py read it as before)
# OUT.npz t (epoch per row), fft (rows x 2048, dB, centred on the tuned frequency), rate,
#         center_hz, target_hz: spectrogram.py render-iq draws it
#
# Chain: mix down by OFFSET -> /9 (264.6 kHz) -> /6 (44.1 kHz, +/-22 kHz: the FM signal and
# the ISS's +/-10 kHz Doppler on 70 cm) -> FM discriminator -> /2 -> DC removed -> 22 050 Hz.
# Every filter keeps its state between blocks, so the audio has no clicks at block edges.

import sys
import time

import numpy as np
from scipy import signal

RATE = 2381400
OFFSET = RATE // 9          # 264 600 Hz
AUDIO = RATE // 108         # 22 050 Hz
BLOCK = RATE // 10          # 0.1 s; a multiple of 108
NFFT = 2048
FFTS_PER_BLOCK = 8          # spectra averaged per 0.1 s (80 per second's row)


class Decimator:
  """FIR low-pass + keep every d-th sample, stateful across blocks (overlap-save with upfirdn)."""

  def __init__(self, d, cutoff, k=8):
    self.d = d
    self.h = signal.firwin(k * d + 1, cutoff).astype(np.float32)   # len - 1 is a multiple of d
    self.buf = None

  def __call__(self, x):
    buf = x if self.buf is None else np.concatenate((self.buf, x))
    L, d = len(self.h), self.d
    if len(buf) < L:
      self.buf = buf
      return buf[:0]
    n = (len(buf) - L) // d + 1
    full = signal.upfirdn(self.h, buf[:(n - 1) * d + L], down=d)
    out = full[(L - 1) // d:(L - 1) // d + n]
    self.buf = buf[n * d:]
    return out.astype(buf.dtype, copy=False)


def main():
  if len(sys.argv) != 4:
    sys.exit('usage: iq_fm.py OUT.npz CENTER_HZ TARGET_HZ  (u8 I/Q on stdin, audio on stdout)')
  out_file, center, target = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])

  mix = np.exp(-2j * np.pi * OFFSET / RATE * np.arange(9)).astype(np.complex64)
  mix = np.tile(mix, BLOCK // 9)
  d1 = Decimator(9, 0.5 / 9, k=4)               # 264.6 kHz, pass +/-66 kHz (37 taps: d2 does the rest)
  d2 = Decimator(6, 1.0 / 6 * 0.9, k=16)        # 44.1 kHz, pass +/-19.8 kHz
  d3 = Decimator(2, 0.5 * 0.85, k=20)           # audio 22 050 Hz, pass 9.4 kHz
  window = np.hanning(NFFT).astype(np.float32)
  b_dc, a_dc = [1, -1], [1, -0.9995]             # DC blocker (like rtl_fm -E dc)
  zi_dc = np.zeros(1)
  last = np.complex64(1)
  scale = (1 << 14) / np.pi                      # rtl_fm's discriminator scale

  rows, times = [], []
  acc, nacc, row_t = np.zeros(NFFT, np.float64), 0, time.time()
  stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
  while True:
    raw = stdin.read(BLOCK * 2)
    if len(raw) < 2 * 108:
      break
    n = (len(raw) // 2) // 108 * 108
    u = np.frombuffer(raw[:2 * n], np.uint8).astype(np.float32)
    x = ((u[0::2] - 127.5) + 1j * (u[1::2] - 127.5)).astype(np.complex64) / 127.5

    # spectrum of the whole band
    seg = n // FFTS_PER_BLOCK
    for i in range(FFTS_PER_BLOCK):
      s = x[i * seg:i * seg + NFFT]
      if len(s) == NFFT:
        acc += np.abs(np.fft.fft(s * window)) ** 2
        nacc += 1
    if nacc >= FFTS_PER_BLOCK * 10:
      rows.append((10 * np.log10(np.fft.fftshift(acc / nacc) + 1e-12)).astype(np.float16))
      times.append(row_t)
      acc[:], nacc, row_t = 0, 0, time.time()

    # FM demodulation of the ISS frequency
    y = d2(d1(x * mix[:n]))
    if len(y):
      prev = np.concatenate(([last], y[:-1]))
      last = y[-1]
      fm = np.angle(y * np.conj(prev)).astype(np.float32) * scale
      a = d3(fm)
      a, zi_dc = signal.lfilter(b_dc, a_dc, a, zi=zi_dc)
      if stdout is not None:
        try:
          stdout.write(np.clip(a, -32767, 32767).astype('<i2').tobytes())
          stdout.flush()
        except BrokenPipeError:            # the decoder ended early: keep the spectrogram going
          stdout = None

  if rows:
    np.savez_compressed(out_file, t=np.array(times), fft=np.stack(rows), rate=RATE,
                        center_hz=center, target_hz=target)


if __name__ == '__main__':
  try:
    main()
  except BrokenPipeError:
    pass
