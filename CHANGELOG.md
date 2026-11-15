# Changelog

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
