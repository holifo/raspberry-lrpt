# Changelog

## Raspberry-LRPT v1.27.0 (2026-11-16)

- **The Meteor-M tab is now "Sat info"** (still at `/meteor`, short label "Info" on phones), with
  the ISS added under the Meteor-M series as an extra: its card (launch, years in orbit, crewed
  since, NORAD/COSPAR, orbit, callsigns RS0ISS/NA1SS, the planned 2030 deorbit, a link to the map),
  its amateur radio (SSTV on 437.550 MHz Robot 36 or 145.800 MHz PD120, the frequency this station
  records, the voice repeater, APRS and crew voice), the year's ARISS SSTV events, and the sources.
  The ISS part shows only with `iss_sstv` on. All texts in the nine languages.

## Raspberry-LRPT v1.26.0 (2026-11-16)

- **ISS SSTV on 70 cm, in Robot 36.** ARISS's 2026 events (April, May, October) sent their pictures
  on 437.550 MHz FM in Robot 36, not on 145.800 MHz in PD120. New setting `iss_sstv_frequency`
  (437.550 by default; 145.800 for a 2 m event); the gain default is now 40.
- **Robot 36 decoder:** `sstv_decode.py` now also locks onto Robot 36's 9 ms line syncs, tells
  its alternating colour lines apart by their separator tone (by majority, so a noisy line can't
  swap the colours), and straightens the slant like the PD decoder. Tested through a simulated
  70 cm FM channel with ±9 kHz Doppler and clock error: full, correctly coloured pictures down to
  weak signals, and two pictures two minutes apart in one pass. One recording can hold both
  families; the decoder finds the mode itself.
- The website's ISS texts (Passes legend, capture page note, image legend, Satellites details) show
  the frequency in use.

## Raspberry-LRPT v1.25.1 (2026-11-16)

- **SatDump for Trixie PCs:** `software/` now has the SatDump 1.2.3 package for Trixie on 64-bit
  PCs (`satdump_1.2.3-0b654b4ec_trixie_amd64.deb`, built with `build_satdump_deb.sh` on Linux Mint
  Debian Edition 7), so a Trixie PC installs without building it. Trixie Raspberry Pis still build
  theirs once (arm64).

## Raspberry-LRPT v1.25.0 (2026-11-16)

- **ISS SSTV pictures.** During ARISS events the ISS sends slow-scan TV pictures on 145.800 MHz FM.
  Between Meteor passes the station now records the ISS's passes (above 20°) with `rtl_fm` and
  decodes them (`scripts/receive_iss.sh`); a Meteor pass always wins an overlap. On by default;
  a pass with no pictures leaves nothing behind. RTL-SDR only. See [docs/iss_sstv.md](docs/iss_sstv.md).
  - **Decoder** (`scripts/image_processors/sstv_decode.py`): for PD120, PD180, PD90 and the other
    PD modes it locks onto every line's sync pulse and fits their timing, so weak, noisy or
    drifting passes still give straight, correctly coloured pictures, and a pass that starts
    mid-picture gives its lower part. Tested through a simulated noisy FM channel with Doppler and
    clock error. Other modes go to the `sstv` Python package (installed on 64-bit systems).
  - **Website:** ISS captures are violet cards on the Captures page (filter chip **ISS**, picture
    count), with the pictures, the sky track, a note about ARISS and the recording (`.wav`). ISS
    passes are in the pass list in violet; the Satellites tab shows the ISS on the map (its own
    track and footprint) and has an ISS tab. "Best pass" stays a Meteor pass.
  - **Settings:** `iss_sstv` (true), `iss_sstv_dates` (only between two dates, e.g. an announced
    event; empty = every pass), `iss_sstv_min_elevation` (20), `iss_sstv_gain` (30).
  - **Meteor always has priority:** an overlapping ISS pass is not scheduled (whatever its
    elevation), an ISS recording ends 20 s before the next Meteor pass (skipped with under a minute
    left), and a Meteor pass that finds an ISS recording running stops it and takes the SDR.
  - Discord posts include the ISS's pictures.
  - `select_best_overlapping_passes.py` no longer fails when `atq` is empty, and the scripts that
    check for a running capture match only the capture scripts themselves.

## Raspberry-LRPT v1.24.2 (2026-11-16)

- **Debian-based systems:** the install, the SatDump build script, the upgrade script, the
  histogram and the uninstaller now use Debian's own release name (`DEBIAN_CODENAME`) when the
  system has one, so Linux Mint Debian Edition 7 ("Gigi") counts as Trixie. Before, the SatDump
  build named its package `…_gigi_…` and the install didn't accept the system.
- **SatDump build on a small `/tmp`:** where `/tmp` is a RAM disk with less than 4 GB free (Trixie),
  `build_satdump_deb.sh` builds in `~/.cache` instead of stopping (`TMPDIR` still chooses).

## Raspberry-LRPT v1.24.1 (2026-11-15)

- **Trixie on a 64-bit PC:** the bundled amd64 `predict` package needs ncurses 5, which Trixie
  doesn't have, so there the install builds `predict` 2.2.5 from its author's repository
  (github.com/kd2bd/predict, pinned commit) into a package. Its pass predictions match the
  bundled packages' to the second. Raspberry Pis and Bookworm keep the bundled packages.

## Raspberry-LRPT v1.24.0 (2026-11-15)

- **Raspberry Pi OS Trixie (Debian 13)**, as well as Bookworm. The install picks each release's
  package names: PHP 8.4 on Trixie (8.2 on Bookworm) with the matching nginx socket,
  `libvolk-dev`, `libncurses-dev`, envbash on both; `libatlas-base-dev` (MeteorDemod only) is
  gone. The web panel was tested on PHP 8.4: every page, no deprecation warnings.
- **SatDump on Trixie:** `scripts/tools/build_satdump_deb.sh` builds the same SatDump 1.2.3 commit
  as the Bookworm package, once, on a Trixie Pi (about an hour) into
  `software/satdump_<version>_trixie_<arch>.deb`. Until a station has it, the install stops at
  step 1 and says so. See [docs/trixie.md](docs/trixie.md).
- **The image label is drawn with Pillow** instead of wkhtmltoimage (which Trixie dropped). It looks
  the same: logo, station and pass details on a 70% transparent panel with rounded corners. The
  layout is now `config/annotation/annotation.yml` (logo, two columns of lines with `{setting}`
  values, font) instead of the HTML template; if you had changed `annotation.html.j2`, move the text
  there. See [docs/annotation.md](docs/annotation.md). wkhtmltopdf is no longer installed.
- **RTL-SDR Blog driver as packages:** the install builds the RTL-SDR Blog driver (RTL-SDR Blog V4
  support) with its own Debian packaging into `librtlsdr0` and `rtl-sdr` .debs from a pinned
  commit and installs them with apt (the `1:` epoch keeps them over Debian's librtlsdr). It
  replaces the osmocom build in `/usr/local`, which the install removes, and the old trick of
  deleting Debian's library files.
- The install's summary checks the station's own receiver on USB (not only RTL-SDRs) and the
  PHP-FPM service of whichever PHP is installed.

### Upgrade

```bash
cd ~/raspberry-lrpt && git pull && ./install_and_upgrade.sh
```

Bookworm stations need nothing else: the install swaps the RTL-SDR driver for the packages (about
a minute) and the labels look the same.

## Raspberry-LRPT v1.23.0 (2026-11-15)

- **All of raspberry-noaa-v2's receivers again:** besides RTL-SDR and Airspy (Mini, R2, HF+
  Discovery), the HackRF One, SDRplay RSPs and MSi2500/MSi001 (MiriSDR) receivers. The install
  asks for the receiver from a numbered list, suggests a gain for it and checks its range, and
  sets up only what that receiver needs: RTL-SDR's osmocom tools and blacklist, the Airspy or
  HackRF tools and udev rules, the Mirics kernel drivers blacklisted for MiriSDR and SDRplay. See
  [docs/receivers.md](docs/receivers.md).
- **SDRplay:** after you accept SDRplay's licence in the setup questions, the install downloads
  SDRplay's API 3.15.2 from sdrplay.com (checked against its SHA-256), installs it with its
  udev rules and the `sdrplay` service, and builds SatDump's SDRplay plugin on the Pi (the
  SatDump package has none). Built and tested without an SDRplay receiver: the plugin builds and
  SatDump loads it, so the first real pass is its first test.
- The gain setting is passed the way each receiver understands it: HackRF LNA then VGA, SDRplay
  IF gain (LNA state 5), MiriSDR in 10 dB steps; the Airspy HF+ uses automatic gain.
  `sdr_extra_options` adds SatDump options to every capture (e.g. `--amp`, `--lna_gain 20`).
- **Upgrade from raspberry-noaa-v2:** `scripts/tools/upgrade_from_noaa_v2.sh` moves a
  raspberry-noaa-v2 station over: its settings (location, receiver, gains, web login, the Meteor
  Discord webhook) and its Meteor captures. It stops the old jobs, moves the NOAA captures and the
  old folder to a backup folder and runs the install. On an older system, `--export` saves the
  station to a file and `--import` loads it on a fresh Bookworm. See
  [docs/upgrade_from_noaa_v2.md](docs/upgrade_from_noaa_v2.md).
- The verification tool checks the drivers of the station's receiver.
- An existing install is now recognised by `~/.raspberry-lrpt.conf`, so stations without an
  RTL-SDR aren't treated as a first install.

### Upgrade

```bash
cd ~/raspberry-lrpt && git pull && ./install_and_upgrade.sh
```

Nothing to change for an existing RTL-SDR or Airspy station.

## Raspberry-LRPT v1.22.1 (2026-11-15)

- Docs: the README's install text mentions the optional Discord webhook and that an upgrade asks
  newly added questions once; `docs/troubleshooting.md` points to this project's GitHub issues
  instead of upstream's Discord server.

## Raspberry-LRPT v1.22.0 (2026-11-15)

- **Post earlier captures to Discord:** `./scripts/discord_post.sh` posts captures already on the
  site, the same way new passes are posted: by number (`-l` lists the newest 20), the newest N
  (`--last N`), or a whole day (`--today`, `--day YYYY-MM-DD`). It asks first (`-y` doesn't),
  posts oldest first and skips captures whose images are gone.
- Posts leave out the direction or length when the pass record doesn't have them.

## Raspberry-LRPT v1.21.1 (2026-11-15)

- User guide: a **Posting to Discord** section (how to turn it on and off, what gets posted, keeping
  the webhook private, with a diagram) and a troubleshooting row for missing posts.

## Raspberry-LRPT v1.21.0 (2026-11-15)

- **Posting to Discord** is back, as an option: each pass that made images is posted to a
  Discord channel through a webhook, with a short message (satellite, local and UTC time, maximum
  elevation, direction, day or night, station name, a link to the capture's page), the pass's best
  images (`discord_images`, default 2, picked from the day or night thumbnail list) and the sky
  track (`discord_sky_track`). Images over Discord's 10 MB limit are posted smaller. Off until a
  webhook is given ([docs/discord.md](docs/discord.md)).
- The install asks for the webhook (and the web panel's public address for the link) once on an
  upgrade, and keeps it in `config/settings.local.yml`, not in git. `~/.raspberry-lrpt.conf` is now
  readable by the station user only (mode 600). The log never shows the webhook.
- `./scripts/push_discord.sh --test` posts a test message.

## Raspberry-LRPT v1.20.0 (2026-11-15): first public release

A Raspberry Pi ground station for METEOR-M2 3 and M2 4 (LRPT, 137.9 MHz), decoding live with
SatDump 1.2.3. An LRPT-only rework of [raspberry-noaa-v2](https://github.com/jekhokie/raspberry-noaa-v2).

- **Install:** one script (`install_and_upgrade.sh`) with setup questions for your station
  (name, location, receiver, gains, bias tee, web port, admin login, SD card or SSD), Ansible with
  compact output, database migrations, web panel deploy and scheduling. Raspberry Pi OS Bookworm
  64-bit; RTL-SDR or Airspy (Mini, R2, HF+ Discovery).
- **Every pass:** scheduled above 15° from CelesTrak orbits, recorded day and night, decoded live,
  every MSU-MR composite the channels allow (corrected and map-projected, with capital cities),
  a grey image per channel, a label with your station's details, a spectrogram, a sky track and an
  elevation/azimuth graph. The decoded frames of the last passes are kept for offline
  re-processing (`scripts/reprocess_meteor.sh`).
- **Daily map:** each day's passes projected onto one map (daytime AVHRR 221 and night-time
  3.9 µm IR), Equal Earth projection, plus a time-lapse of the day's passes over a chosen area.
- **Web panel** in nine languages, light or dark:
  - Passes: next-pass countdown, passes by day, and a live decode panel while recording
    (spectrum, waterfall, SNR, Viterbi and frame-sync locks, BER).
  - Satellites: live ground-track map with coverage, day/night shading and pass progress, the
    selected satellite's details and the coming passes.
  - Meteor-M: the series, every launch and the planned ones.
  - Captures: foldable days, filters and a zoomable image viewer, with a legend of every image.
  - Daily map, Live log (system dashboard and the station log), Admin.
