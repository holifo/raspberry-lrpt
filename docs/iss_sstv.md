# Extra: ISS SSTV pictures and APRS

The station is a METEOR-M2 LRPT station; the ISS is an extra that uses the receiver between Meteor
passes and never takes a Meteor pass's place.

A few times a year, during **ARISS** events, the International Space Station sends slow-scan TV
(SSTV) pictures, usually a series of twelve, one every few minutes:

- **437.550 MHz FM in Robot 36** (70 cm): ARISS's 2026 events (April, May and October)
- **145.800 MHz FM in PD120** (2 m; sometimes PD180 or PD90): the events before 2026

Set `iss_sstv_frequency` to the event's frequency (437.550 by default); the decoder finds the mode
itself. Between Meteor passes the station records the ISS's
passes and decodes those pictures. ARISS announces the events on [ariss.org](https://www.ariss.org/)
and on the [ARISS SSTV blog](https://ariss-sstv.blogspot.com/).

It is **off by default**; turn it on with the switch on Admin > Passes or
`scripts/switch.sh iss on` (below). Between events it records the ISS's APRS digipeater instead
(below). A pass where nothing was decoded leaves nothing behind, so you only see the ISS on the
site when something was received.

## How it works

1. **Orbit:** `schedule.sh` downloads the ISS's orbit from CelesTrak (NORAD 25544) with the Meteor
   orbits, into `tmp/iss.tle`. A failed download keeps the previous one.
2. **Scheduling:** every ISS pass whose highest point is above `iss_sstv_min_elevation` (20°) is
   scheduled with `at`, like the Meteor passes, and shows in the pass list in violet. With
   `iss_aprs: false` and `iss_sstv_dates` set, only the passes between those dates are (with APRS
   on, every pass is, and the dates decide SSTV or APRS).
3. **Meteor always has priority**, at every step:
   - **Scheduling:** when an ISS pass overlaps a Meteor pass, the Meteor pass is kept and the ISS
     pass dropped, however high the ISS pass is (`select_best_overlapping_passes.py`).
   - **Before recording:** an ISS recording ends 20 s before the next Meteor pass starts; with
     less than a minute left it is skipped. It also waits up to a minute for a Meteor capture
     that is still running, then gives up.
   - **During recording:** a Meteor pass that starts while the ISS is still being recorded stops
     that recording and takes the SDR (the pictures received so far are still decoded).
4. **Recording** (SSTV; APRS is below): `receive_iss.sh` records the pass on `iss_sstv_frequency` with `rtl_fm`
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

## Turning it on or off

The ISS is an extra and is off by default. Switch it (or the Meteor captures) any time, without
running the whole install:

- **On the website:** Admin > Passes (`/admin/passes`, behind the admin login) has a Meteor and an
  ISS switch at the top. A change is refused while a pass is being recorded and for two minutes
  after the last change, only clicks made on the station's own pages count, and each change is
  written to the Live log. The web server may run only `switch.sh --web meteor|iss on|off`, as
  the station's user (`/etc/sudoers.d/030_www-data-switch`). While the site has no HTTPS, the admin
  password travels unencrypted; see [tls_webserver.md](tls_webserver.md).
- **On the Pi:**

  ```bash
  ~/raspberry-lrpt/scripts/switch.sh iss on       # schedule the ISS's passes (Meteor keeps priority)
  ~/raspberry-lrpt/scripts/switch.sh iss off      # no ISS passes, the ISS leaves the web panel
  ~/raspberry-lrpt/scripts/switch.sh meteor off   # no Meteor passes (both satellites)
  ~/raspberry-lrpt/scripts/switch.sh              # what is on
  ```

The choice is kept in `config/settings.local.yml`, so later installs keep it. The setup questions
also ask "Also record the ISS's SSTV pictures (extra)" (asked once on an upgrade). A recording
already running finishes.

## Between events: APRS (`iss_aprs`)

Most of the year the ISS sends no pictures, but its **APRS digipeater** is on almost all the
time: radio amateurs send short position and message packets on **145.825 MHz** (1200 baud AFSK),
and the ISS repeats them on the same frequency (via `RS0ISS` / `ARISS`). With `iss_aprs: true`
(the default) the station records those passes instead:

- **Which mode:** inside the `iss_sstv_dates` window a pass is recorded for SSTV pictures; outside
  it (or always, when `iss_sstv_dates` is empty) for APRS. **So for an ARISS event, set
  `iss_sstv_dates`** to the event's days.
- **Decoding:** `rtl_fm` on 145.825 MHz feeds [Dire Wolf](https://github.com/wb2osz/direwolf)
  (the `direwolf` package), which writes each packet to a log as it is heard.
- **Live map:** while a pass is recorded, the **Satellites** map shows each station heard so far as
  a violet dot with its call sign (grey: heard directly, not through the ISS), and a box at the
  bottom left counts them. The map asks the station (`/passes/aprs`) every 5 seconds.
- **After the pass:** a capture with a map of the stations and the ISS's track, a table of the
  stations (call sign linked to aprs.fi, time, packets, distance, comment) and the packets as
  received. The Captures card says "N APRS". Discord posts the map. The 2 m audio is kept as a
  `.wav` like the SSTV recordings (`keep_recordings`).
- Passes where nothing was decoded leave no trace, as with SSTV.
- 145.825 MHz is 2 m, so a 2 m QFH hears it well; packets are short, so expect a handful of
  stations on a good pass, more over Europe at weekends.

Set `iss_aprs: false` to record only SSTV (then every pass is an SSTV pass when `iss_sstv_dates`
is empty, as before v1.31.0).

## Settings

| Setting | Default | What it does |
|---|---|---|
| `iss_sstv` | false | Record and decode the ISS's passes |
| `iss_sstv_dates` | "" | Only between these dates, `"YYYY-MM-DD YYYY-MM-DD"` (an ARISS event); empty = every pass |
| `iss_sstv_min_elevation` | 20 | Lowest maximum elevation of a pass worth recording |
| `iss_sstv_frequency` | 437.550 | The downlink to record (MHz): 437.550 (70 cm) or 145.800 (2 m), whichever the event uses |
| `iss_sstv_gain` | 40 | The RTL-SDR's gain for the ISS |
| `iss_aprs` | true | Between SSTV events (outside `iss_sstv_dates`), record the ISS's APRS digipeater on 145.825 MHz |

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
