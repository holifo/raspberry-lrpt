# ISS SSTV pictures

A few times a year, during **ARISS** events, the International Space Station sends slow-scan TV
(SSTV) pictures, usually a series of twelve, one every few minutes:

- **437.550 MHz FM in Robot 36** (70 cm): ARISS's 2026 events (April, May and October)
- **145.800 MHz FM in PD120** (2 m; sometimes PD180 or PD90): the events before 2026

Set `iss_sstv_frequency` to the event's frequency (437.550 by default); the decoder finds the mode
itself. Between Meteor passes the station records the ISS's
passes and decodes those pictures. ARISS announces the events on [ariss.org](https://www.ariss.org/)
and on the [ARISS SSTV blog](https://ariss-sstv.blogspot.com/).

It is **on by default**. Passes with no pictures (most of the year) leave nothing behind, so you
only see the ISS on the site when it actually sent something.

## How it works

1. **Orbit:** `schedule.sh` downloads the ISS's orbit from CelesTrak (NORAD 25544) with the Meteor
   orbits, into `tmp/iss.tle`. A failed download keeps the previous one.
2. **Scheduling:** every ISS pass whose highest point is above `iss_sstv_min_elevation` (20°) is
   scheduled with `at`, like the Meteor passes, and shows in the pass list in violet. With
   `iss_sstv_dates` set, only the passes between those dates are.
3. **Meteor always has priority**, at every step:
   - **Scheduling:** when an ISS pass overlaps a Meteor pass, the Meteor pass is kept and the ISS
     pass dropped, however high the ISS pass is (`select_best_overlapping_passes.py`).
   - **Before recording:** an ISS recording ends 20 s before the next Meteor pass starts; with
     less than a minute left it is skipped. It also waits up to a minute for a Meteor capture
     that is still running, then gives up.
   - **During recording:** a Meteor pass that starts while the ISS is still being recorded stops
     that recording and takes the SDR (the pictures received so far are still decoded).
4. **Recording:** `receive_iss.sh` records the pass on `iss_sstv_frequency` with `rtl_fm`
   (48 kHz wide, which covers the ISS's Doppler shift: about ±3.5 kHz on 2 m, ±10 kHz on 70 cm)
   as audio at 11025 Hz, with the gain `iss_sstv_gain`.
5. **Decoding:** `scripts/image_processors/sstv_decode.py` finds the pictures in the audio. For
   Robot 36 and the PD modes it locks onto every line's sync pulse instead of relying on the
   start code (Robot 36 also tells its alternating colour lines apart by their separator tone), fits
   the pulses' timing (which straightens the slant from the receiver's clock error), and reads
   the pixels between them. That way a weak or noisy pass still gives a picture, and a pass that
   starts in the middle of a picture gives its lower part. Other modes (Robot 72, Martin, Scottie)
   go to the `sstv` Python package, which the install adds on 64-bit systems.
6. **On the site:** a pass with pictures becomes a capture (violet **ISS** card on the Captures
   page, with a filter chip), its pictures as `SSTV 1`, `SSTV 2`, … and the sky track, plus the
   recording (`.wav`, kept like the Meteor recordings) for decoding again with any SSTV program.
   The Satellites tab shows the ISS on the map and has an ISS tab with its position and next pass.
   With Discord set up, the pictures are posted too.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `iss_sstv` | true | Record and decode the ISS's passes |
| `iss_sstv_dates` | "" | Only between these dates, `"YYYY-MM-DD YYYY-MM-DD"` (an ARISS event); empty = every pass |
| `iss_sstv_min_elevation` | 20 | Lowest maximum elevation of a pass worth recording |
| `iss_sstv_frequency` | 437.550 | The downlink to record (MHz): 437.550 (70 cm) or 145.800 (2 m), whichever the event uses |
| `iss_sstv_gain` | 40 | The RTL-SDR's gain for the ISS |

Change them in `config/settings.yml` and run `./install_and_upgrade.sh`; to drop passes already
scheduled, run `./scripts/schedule.sh -x` afterwards.

## Notes

- **RTL-SDR only:** the recording uses `rtl_fm`. With another receiver the ISS isn't scheduled
  (the log says so).
- **Antenna:** a **2 m QFH** (cut for 145.8 MHz) is the antenna this documentation assumes for the
  ISS: right for 2 m events, and it still receives the Meteors at 137.9 MHz. A QFH cut for
  137 MHz also hears 145.8 MHz, a little weaker. On 437.55 MHz (70 cm) either QFH is much weaker,
  so a 70 cm event may only decode on high passes, unless you add a 70 cm antenna.

- **Which frequency:** ARISS announces each event on [ariss.org](https://www.ariss.org/), the
  [ARISS SSTV gallery](https://ariss-usa.org/ARISS_SSTV/) and its social media. Set
  `iss_sstv_frequency` (and `iss_sstv_dates`) to match, run the install, then
  `./scripts/schedule.sh -x`.
- **Every pass costs SDR time,** about ten minutes, but never a Meteor pass. If you'd rather record
  only during announced events, put the event's dates in `iss_sstv_dates`.
- **Decode a recording again:** `python3 scripts/image_processors/sstv_decode.py
  /srv/audio/meteor/ISS-<date>.wav /tmp/sstv` writes `/tmp/sstv-1.png`, `-2.png`, …
