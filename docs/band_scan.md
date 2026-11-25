# Band scan (Admin > Band scan)

`/admin/scan` lets you look at a band for a while with one of the station's RTL-SDRs, without
SSH. It is behind the admin login, and its pictures are shown **only** there: they are kept in
`/srv/scans`, which the web server does not serve, and the page hands them out after the login.

## The five bands

| Band | Range | What it is for |
|---|---|---|
| **Meteor band** | 136.9–138.1 MHz, 600 Hz a point | METEOR-M2 LRPT at 137.900 and 137.100 MHz: the signal, its width and anything next to it |
| **2 m amateur band** | 144–146 MHz, 1 kHz | The ISS on 2 m (145.800 voice/SSTV, 145.825 APRS) and other amateur satellites |
| **70 cm satellite band** | 435–438 MHz, 1 kHz | The ISS on 70 cm (437.550 SSTV, 437.800 repeater, 437.825 APRS) and CubeSats |
| **VHF overview** | 108–175 MHz, 25 kHz | Airband, weather satellites, 2 m, marine and AIS at once: find what disturbs reception |
| **FM broadcast band** | 87.5–108 MHz, 10 kHz | Strong FM stations, the most common cause of an overloaded dongle and missed passes |

**Manual range** (v1.48.0): any range from 24 to 1766 MHz (what an R820T/R828D dongle tunes), up
to 300 MHz wide, with a resolution of 250 Hz to 100 kHz a point, or **Automatic** (the finest that
keeps it under about 3,000 points across). A scan may have at most 12,000 points across. The
station's known frequencies inside the range are marked. Ranges wider than 2 MHz hop the tuner
like the wide bands.

Durations: 2, 5, 10, 30 or 60 minutes. The two wide bands hop the tuner across the band (about
2 MHz at a time), so they take a row every 5 seconds or more; the narrow ones every second or so.

## What you get

**While it runs** (v1.49.0): the running scan's box shows a live waterfall of the newest rows,
redrawn about every 15 seconds (less often on very big scans, so drawing never slows the
recording). It appears after the first sweeps; tap it to open it full size.

**When it ends:**

- **Waterfall:** time down, frequency across, one pixel per point; open it to zoom and pan. The
  station's known frequencies are marked.
- **Average and peak:** the band's average and peak level over the scan.
- **Signals:** every run of points whose peak stood 6 dB above the band's floor, with its strongest
  frequency, peak and average level above the noise, its width, and a name when it is a known one.

The newest 20 scans are kept. **Delete** removes one at once.

## Rules

- One scan at a time.
- A scan is refused while that dongle is recording a pass, or when a pass needs that dongle during
  the scan (Meteor passes need the Meteors' dongle; ISS passes the ISS's). A pass that starts anyway
  stops the scan, and what it recorded is still drawn. With two RTL-SDRs, the ISS's dongle is
  usually free.
- The dongle keeps its gain: the Meteors' gain on theirs, `iss_sstv_gain` on the ISS's.
- What you see depends on that dongle's antenna and filters. A 137 MHz LNA with a filter (such as
  the Nooelec SAWbird NOAA) hides every other band.

## How it works

`scripts/band_scan.sh status|start|stop|delete` runs `scripts/tools/band_scan.py` as the station
user (the web server may run only those four commands, `/etc/sudoers.d/030_www-data-switch`).
`rtl_power` records the sweep to a CSV; when it ends, the CSV is drawn
(`spectrogram.full_waterfall`, matplotlib for the spectrum) and deleted. `receive_meteor.sh` and
`receive_iss.sh` call `band_scan_yield` before they record. Run `./install_and_upgrade.sh` once after
updating: it adds the permission and the `/srv/scans` folder.
