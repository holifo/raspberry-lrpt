# Changelog

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
