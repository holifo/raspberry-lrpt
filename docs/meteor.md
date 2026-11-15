# METEOR-M2 LRPT reception

METEOR-M2 3 and METEOR-M2 4 send LRPT: 72k (or 80k) symbols per second OQPSK, about 120 kHz wide,
on 137.9 MHz (both satellites; they have also used 137.1 MHz at times). Each satellite sends three of its six MSU-MR channels at
a time, so the composites a pass can make depend on what it sends.

## How a pass is received

1. `scripts/schedule.sh` schedules each pass above the minimum elevation with `at`.
2. At AOS, `scripts/receive_meteor.sh` runs `satdump live meteor_m2-x_lrpt` (SatDump 1.2.3). SatDump
   demodulates and decodes the signal live, writes the decoded frames (`.cadu`) and, after LOS, builds
   the products: every MSU-MR composite its channels allow, corrected and map-projected.
3. During the pass SatDump's built-in web server (127.0.0.1:8091) is polled once a second for the
   spectrum, SNR and decoder lock: the Passes page shows them live, and they become the pass's
   spectrogram.
4. After the pass the images are rotated on northbound passes, annotated with the station panel,
   turned into JPEGs and thumbnails, and added to the database with the pass graphs.
5. The `.cadu` of the newest `keep_recordings` passes is kept in `/srv/audio/meteor` for offline
   re-processing:

   ```bash
   satdump meteor_m2-x_lrpt cadu <file>.cadu <output folder>
   ```

MeteorDemod can be used instead of SatDump with `meteor_decoder: 'meteordemod'` in `settings.yml`.
