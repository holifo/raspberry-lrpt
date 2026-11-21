# Changelog

## Raspberry-LRPT v1.36.1 (2026-11-21)

- **Install no longer fails on the old PHP repository.** Stations that came from raspberry-noaa-v2
  still had its sury PHP repository in apt's sources, although this project uses Debian's own PHP.
  When that mirror was in the middle of an update, apt refused to refresh and the install stopped at
  "System packages". The install now removes the left-over entry.

## Raspberry-LRPT v1.36.0 (2026-11-21)

- **About tab, with an update check.** The Sat info tab is now **About** (`/about`; old `/meteor`
  links still work). At the top it shows the station's software: the installed version, the latest
  version on GitHub, when it was last checked and, when a new version is out, the command to update.
  Further down are the credits and the Meteor-M and ISS information as before. The station looks for
  a new version once a day and after each install (`scripts/update_check.sh`, a `git fetch` only:
  it never updates itself). When an update is out, the footer of every page says "vX available" and
  links to About. Turn it off with `update_check: false`. On phones the menu shows an ⓘ icon for
  About, so all six items still fit.
- **SDRplay: fixed the API service failing to start** ("sdrplay (stopped)" in the install summary).
  On a station where SDRplay's own installer had been run before, the install found the API library,
  skipped installing the API and started a service program that wasn't there. The install now checks
  for the service program too and installs the API when either is missing.

## Raspberry-LRPT v1.35.0 (2026-11-21)

- **Live picture while a Meteor pass records.** The live decode panel on the Passes page now shows
  a small picture of what has been decoded so far, updated about every 45 seconds: channel 2 by day,
  infrared at night, north up, with its line count. It appears a minute or two into the pass, once
  frames are coming in, and grows as the satellite crosses the sky. Each update decodes the frames
  received so far at the lowest priority and stops SatDump before its slow products step, so it
  takes a few seconds and never gets in the way of the live decode. It is on by default
  (`live_preview`) and skips itself on a Pi with fewer than 4 cores. On phones the picture comes
  right after the spectrum.

## Raspberry-LRPT v1.34.0 (2026-11-21)

- **ISS with one SDR or two, chosen automatically.** With two or more RTL-SDRs the ISS now gets
  its own dongle and records at the same time as the Meteor passes: overlapping passes are all
  kept and nothing is cut short. With one, it works as before: Meteor passes come first, and the
  ISS records when the dongle is free (SSTV on event dates, APRS otherwise). The choice is made
  when passes are scheduled and again when each ISS pass starts, so an unplugged second dongle
  just falls back to the shared rules.
- **Choose the ISS dongle** with the new `iss_sdr_device` setting: empty for automatic, or an
  index, a serial number or part of the model name (e.g. `Blog V4`). `iss_bias_tee` sets the bias
  tee on the ISS's own dongle. `scripts/switch.sh iss` lists the connected RTL-SDRs (index, maker,
  model, serial) and says which one the ISS uses.
- The ISS can now run on a station whose Meteor receiver is an Airspy, HackRF or SDRplay, with an
  RTL-SDR beside it for the ISS.
- The Passes page no longer marks an ISS pass during a Meteor pass as a conflict when the ISS has
  its own dongle.
- **Fix:** with overlapping passes, an ISS pass between two overlapping Meteor passes made the
  scheduler keep both Meteors (the second then found the SDR busy). Each pass is now compared with
  the last pass that was kept.

## Raspberry-LRPT v1.33.0 (2026-11-21)

- **ISS APRS on its new frequency, 437.825 MHz.** ARISS moved the ISS's APRS packet radio from
  2 m (145.825 MHz) to 70 cm (437.825 MHz) in 2026, so the station's APRS recordings heard nothing.
  APRS passes are now recorded on 437.825 MHz, and the frequency is a new setting,
  `iss_aprs_frequency`, in case ARISS moves it again (check ariss.org's station status). The web
  panel, the Discord posts and the APRS maps show the frequency in use. On 70 cm a 2 m QFH hears
  little: a 70 cm or dual-band antenna works much better.

## Raspberry-LRPT v1.32.4 (2026-11-21)

- **Faster orbit (TLE) updates when CelesTrak can't be reached.** Before downloading, the scheduler
  pinged www.celestrak.org and logged "waiting for DNS resolution" every 5 s for a whole minute on
  networks that block ping, then spent up to 5 more minutes retrying CelesTrak before it turned to
  the SatNOGS backup. It now only checks that the name resolves (celestrak.org or db.satnogs.org),
  tries CelesTrak three times with short timeouts, and moves on to SatNOGS in about a minute and a
  half at most.

## Raspberry-LRPT v1.32.3 (2026-11-20)

- **Install fix for Trixie stations that have Debian's own SatDump.** Debian 13 ships SatDump 1.2.2
  as two packages, `satdump` and `satdump-data`. If they were installed, the install stopped at
  "Packages and SatDump" with `trying to overwrite '/usr/include/satdump/…', which is also in
  package satdump-data`. The install now removes any SatDump package that is not the one it brings
  (Debian's, or the old 2.x alpha) before installing SatDump 1.2.3. Just run the update again.

## Raspberry-LRPT v1.32.2 (2026-11-19)

- Removed the `enable_coronal` setting that v1.32.1 left behind in `config/settings.yml`; it no
  longer did anything.

## Raspberry-LRPT v1.32.1 (2026-11-19)

- **Removed two leftovers from raspberry-noaa-v2 on the Passes page:** the satvis 3D globe
  (`enable_satvis`, an outside site in a frame; the Satellites tab is the station's own live map)
  and the NASA coronal mass ejection pictures (`enable_coronal`, which fetched three large images
  from NASA on every visit). Their settings, web panel code, styles and translations are gone. An
  `enable_satvis` or `enable_coronal` line left in your `settings.local.yml` is simply ignored.

## Raspberry-LRPT v1.32.0 (2026-11-19)

- **Image label: choose its look.** The station label on capture images was always light grey and
  70% see-through. Now you can set:
  - `annotation_style`, a look for each purpose: `light` (the classic, for daytime colour images),
    `dark` (navy with white text, for night and IR images), `auto` (light for daytime passes, dark
    at night), `white` (a clean card for sharing and printing), `black` (to match the black band of
    `extend_for_annotation`) or `clear` (no panel, outlined text, covering as little of the picture
    as possible)
  - `annotation_transparency`: 0 (solid) to 100 (no panel); text and logo stay solid
  - `annotation_background`, `annotation_text_colour`, `annotation_border_colour`: your own
    `#rrggbb` colours over the style's

  The quickest way is the new `scripts/label.sh` (e.g. `scripts/label.sh auto 60`,
  `scripts/label.sh text '#f2b33d'`, `scripts/label.sh preview`); it keeps the choice in
  `config/settings.local.yml`. Nothing changes until you choose: the default is the classic label.
  See [the label docs](docs/annotation.md#choosing-a-look).
- `scripts/tools/settings.py set` keeps text settings as typed (a colour like `#3a2600` was read as
  a YAML comment) and checks values against the settings schema before saving them.

## Raspberry-LRPT v1.31.7 (2026-11-19)

- **Image label: no empty field.** The third line of the label on every image read
  `Direction: Northbound |  | Gain: 48`: the `{enhancement}` value between the two bars was a
  leftover from raspberry-noaa-v2 that the Meteor scripts never fill in. It is gone from the label
  (`annotation.yml`), the docs and the annotation script, so the line now reads
  `Direction: Northbound | Gain: 48`. If you keep your own `annotation.yml`, remove `| {enhancement}` from it.

## Raspberry-LRPT v1.31.6 (2026-11-19)

- **Satellites map: a pass now ends when the recording ends.** The Passes tab and the recording
  use the pass from horizon to horizon (as the schedule predicts it), but the map's progress panel
  only counted the part above the minimum elevation (15°), so it showed a pass as finished a few
  minutes early while the Passes tab still counted down. The map now uses the same horizon-to-horizon
  window for the progress panel, "In range", the satellite details and "Next pass"; passes that never
  reach the minimum elevation (which the station doesn't record) are still left out.

## Raspberry-LRPT v1.31.5 (2026-11-19)

- **ISS APRS: every packet in the Live log.** While an ISS APRS pass is recorded, each packet
  Dire Wolf decodes is now written to the station log straight away, so the Live log follows the
  pass as well as the Satellites map: call sign, whether it came through the ISS (or was heard
  directly), its position and its comment, e.g.
  `APRS heard N0CALL-7 via RS0ISS · 38.25 N 21.73 E · "Mobile via ARISS"`.

## Raspberry-LRPT v1.31.4 (2026-11-19)

- **Orbits: the SatNOGS DB is the backup when CelesTrak can't be reached.** `schedule.sh` still
  downloads the Meteor and ISS orbits (TLEs) from CelesTrak first. If that fails after its tries,
  it now asks the SatNOGS DB (Libre Space Foundation; no account needed), and only keeps
  yesterday's orbits when both fail. The log says which source was used.
- **SatDump no longer downloads its own orbits at every start.** Once its copy was a day old,
  SatDump 1.2.3 tried to download CelesTrak's whole satellite list when a recording started, and
  when CelesTrak couldn't be reached it retried 10 times, about 2 minutes each. That could hold a
  pass's recording back by up to 20 minutes, so the satellite was gone by the time it started. The
  station already gives SatDump its orbits, so the install now turns SatDump's own download off
  (`~/.config/satdump/settings.json`). Run the install to get this.

## Raspberry-LRPT v1.31.3 (2026-11-19)

- **Docs: troubleshooting for SDRplay receivers** in `docs/receivers.md`: how to check that the
  receiver is seen (USB, SDRplay's service, the plugin, a probe), whether a pass recorded a signal
  (SNR and sync in the log), a 10-second test recording that shows whether the receiver delivers
  samples or is overloaded, and the antenna-side causes (an LNA that needs the bias tee, the antenna
  socket, gain). Learned from the first RSP1A stations.

## Raspberry-LRPT v1.31.2 (2026-11-19)

- **Live log: the SDR card now finds every supported receiver.** It only looked for an RTL-SDR,
  so an SDRplay, Airspy, HackRF or MiriSDR always showed "not detected", even when it was plugged
  in and working. It now looks for the station's own receiver (the one chosen in the setup
  questions) by its USB ids, the same ones the install checks.
- **Live log: your receiver's driver errors are shown.** SatDump logs an "Error loading" line for
  every SDR driver a station doesn't use, and the console hid those lines for all receivers but
  the RTL-SDR. It now hides them only for the drivers you don't use, so a missing SDRplay, Airspy
  or HackRF driver shows up.

- **Satellites tab: the ISS's downlink now lists APRS too** (145.825 MHz), next to the SSTV
  frequency, when ISS APRS is on.

## Raspberry-LRPT v1.31.1 (2026-11-19)

- **MeteorDemod removed: SatDump is the only decoder.** The documentation still said MeteorDemod
  could be used instead (`meteor_decoder: 'meteordemod'`), but that path was a leftover from
  raspberry-noaa-v2 that this project never tested, and MeteorDemod's current source no longer
  builds with the compilers in Trixie. The setting, its build, its config and its checks are gone;
  an upgrade deletes an old MeteorDemod build if there is one. A `meteor_decoder` line left in
  your own settings is simply ignored.
- **ISS switch text:** on Admin > Passes the ISS switch now says it records SSTV pictures during
  ARISS events and APRS on the other passes (in all nine languages).
- **Docs** brought up to date for ISS APRS (user guide, hardware, README credits: Dire Wolf).

## Raspberry-LRPT v1.31.0 (2026-11-19)

- **ISS APRS between SSTV events, with a live map.** Most of the year the ISS sends no SSTV
  pictures, but its APRS digipeater is on: radio amateurs' position and message packets, repeated
  on 145.825 MHz. With the ISS extra on, passes outside the `iss_sstv_dates` window (or every pass
  when it is empty) are now recorded for APRS and decoded with Dire Wolf (new `direwolf` package):
  - **live:** while a pass is recorded, the Satellites map shows each station heard so far as a dot
    with its call sign, and a box counts them (updated every 5 seconds)
  - **after the pass:** a capture page with a map of the stations and the ISS's track, a table of
    stations (call sign linked to aprs.fi, time, packets, distance) and the packets as received; the
    Captures card says "N APRS"; Discord posts the map
  - passes where nothing was decoded leave no trace, as with SSTV
  - new setting `iss_aprs` (true); `false` records SSTV only, as before. For an ARISS SSTV event,
    set `iss_sstv_dates` to its days. Texts in all nine languages.

## Raspberry-LRPT v1.30.3 (2026-11-17)

- **New top menu order:** Passes · Captures · Daily map · Satellites · Sat info · Live log. What
  comes next first, then the station's pictures, then the satellites, and the station log last
  (Captures and Daily map used to come after Satellites and Sat info). On phones the short labels
  follow the same order: Passes · Captures · Map · Sats · Info · Log.

## Raspberry-LRPT v1.30.2 (2026-11-16)

- **The checks after a first install no longer report hundreds of false failures.** On a new
  Trixie Pi the verification tool said "Failing tests 239" for an install that had worked. Its
  list of file modes was an old snapshot from raspberry-noaa-v2, with files that no longer exist
  (MeteorDemod, old SatDump debs, old templates) and modes that a group-writable system (umask 002,
  as on Raspberry Pi OS Trixie) never matches. Now:
  - it checks the paths that matter (settings file 600, database, folders), accepts an extra
    group-write bit, checks that every script git marks executable is executable, and checks
    MeteorDemod's files only when MeteorDemod is the decoder
  - a package counts only when it is really installed (it used to pass names apt merely knew of),
    and the list matches what the install puts on (`libncurses-dev`, `libvolk-dev` on Trixie)
  - the web panel test uses the station's own port and HTTPS setting, and says what it got
    (it tried port 80 and showed SatDump's last log line as the reason)
  - NTP's file is `/etc/ntpsec/ntp.conf`; a program that is missing fails clearly
  - `build_permissions_list.sh` (it copied the upstream author's home folder) is gone

## Raspberry-LRPT v1.30.1 (2026-11-16)

- **Fix: the SDRplay install failed** at "SDRplay API installed" with
  *cd: /tmp/sdrplay_api: No such file or directory*. SDRplay's 3.15.2 installer did not unpack
  with `--noexec --target`. It is now unpacked with `--tar xf` (the way the Arch Linux package
  does it), with the old way as a fallback. The library is found wherever it lands, and if both
  ways fail the install shows the installer's own message and what it unpacked.

## Raspberry-LRPT v1.30.0 (2026-11-16)

- **"About this software" on the Sat info page:** a box at the bottom (with an "About" jump link at
  the top) says who made Raspberry-LRPT and that it was made with the help of AI: much of the code,
  documentation and translations were written by Claude, Anthropic's AI assistant (most recently
  Claude Opus 5.5, through Claude Code), to holifo's instructions, and tested on a working station.
  It also notes that AI can make mistakes and asks people to report them on GitHub. In all nine
  languages.

## Raspberry-LRPT v1.29.2 (2026-11-16)

- **Fix: the install failed on Trixie** at "Packages and SatDump" with *Dependency is not
  satisfiable: libhdf5-hl-100t64|libhdf5-hl-100|libhdf5-103|libhdf5-100*. Both Trixie SatDump
  packages (arm64 and amd64) link to HDF5 1.14, which Trixie ships as `libhdf5-310` and
  `libhdf5-hl-310`, but their dependency list (copied by SatDump's build from its settings for
  older releases) named the older packages. The list now names the Trixie ones, plus four
  libraries SatDump's core links to and the list left out (TIFF, curl, OpenCL, OpenMP). The
  programs inside the packages are unchanged.
- `scripts/tools/fix_satdump_deb_depends.sh FILE.deb` does this fix, and `build_satdump_deb.sh`
  now runs it after building, so a package you build yourself installs too.

## Raspberry-LRPT v1.29.1 (2026-11-16)

- **Trixie on a Raspberry Pi now installs straight away:** the SatDump 1.2.3 package for Trixie on
  arm64 (`software/satdump_1.2.3-0b654b4ec_trixie_arm64.deb`, built on a Raspberry Pi 3 B+ with
  `build_satdump_deb.sh`) is now in the repository, next to the amd64 one. There is no need to
  build SatDump on the Pi first any more.

## Raspberry-LRPT v1.29.0 (2026-11-16)

- **On/off switches on the website:** Admin > Passes now has two switches at the top, one for the
  Meteor captures (METEOR-M2 3 and M2 4 together) and one for the ISS extra. A switch takes effect
  straight away: off removes that satellite's scheduled passes, on schedules them again (Meteor
  keeps priority over the ISS). Safeguards: the admin login, only clicks from the station's own
  pages, refused while a pass is being recorded and for two minutes after the last change, each
  change written to the Live log. The web server may run only those four switch commands (a sudo
  rule), nothing else. Texts in all nine languages.
- **The same from the Pi:** `scripts/switch.sh meteor|iss on|off` (no argument shows what is on).
  `scripts/iss_sstv.sh` from v1.28.0 still works.
- **The ISS is now off by default** (`iss_sstv: false`); Meteor stays on. Turn the ISS on with its
  switch. An upgrade's setup question about the ISS now suggests "no".

## Raspberry-LRPT v1.28.0 (2026-11-16)

- **On/off switch for the ISS extra:** `scripts/iss_sstv.sh on|off` turns ISS SSTV on or off
  straight away, without the whole install: it saves the choice, updates the station's settings and
  the web panel, removes the ISS's scheduled passes (off) or schedules them again with Meteor
  first (on). Without an argument it says whether it is on. The setup questions now ask "Also
  record the ISS's SSTV pictures (extra)" too (once on an upgrade; RTL-SDR stations only).

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
