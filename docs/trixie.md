# Raspberry Pi OS Trixie

Raspberry-LRPT runs on Raspberry Pi OS **Bookworm** and **Trixie** (Debian 12 and 13), 64-bit. The
install picks the right package names for each:

| | Bookworm | Trixie |
|---|---|---|
| PHP | 8.2 | 8.4 |
| VOLK headers | `libvolk2-dev` | `libvolk-dev` |
| ncurses headers | `libncurses-dev` | `libncurses-dev` |
| RTL-SDR driver | RTL-SDR Blog packages | RTL-SDR Blog packages |
| Image label | Pillow | Pillow |
| SatDump 1.2.3 | in `software/` | built once on the Pi (below), unless `software/` has it |

## SatDump on Trixie

The station uses SatDump 1.2.3 from a fixed commit (the same on both releases), as a package in
`software/` named `satdump_<version>_<release>_<arch>.deb`. When there is none for Trixie yet, the
install stops at step 1 and says so. Build it once:

```bash
cd ~ && git clone https://github.com/holifo/raspberry-lrpt raspberry-lrpt
~/raspberry-lrpt/scripts/tools/build_satdump_deb.sh
cd ~/raspberry-lrpt && ./install_and_upgrade.sh
```

`build_satdump_deb.sh` installs the build tools, builds and installs the RTL-SDR Blog driver
packages, then builds SatDump the way SatDump's own CI does and writes
`software/satdump_1.2.3-0b654b4ec_trixie_arm64.deb`. It takes about an hour on a Raspberry Pi 4 or
5 and needs about 4 GB of free disk. With less than 8 GB of RAM it builds with 2 jobs; if the
compiler is killed, add swap or run it with `-j 1`.

Once one Trixie station has built it, the package can be added to the repository's `software/`
folder so other Trixie stations install it straight away.

## Moving a station from Bookworm to Trixie

Raspberry Pi recommends a fresh install rather than upgrading Bookworm to Trixie in place: put Trixie on a
new card and
install the station again. To keep the captures and settings, copy these off the old card first and
back after the install:

- `~/raspberry-lrpt/config/settings.local.yml` (your answers; private)
- `~/raspberry-lrpt/db/panel.db` (the capture list)
- `/srv/images` and `/srv/audio/meteor` (images and recordings)

A raspberry-noaa-v2 station can use [the upgrade script's --export and --import](upgrade_from_noaa_v2.md).

## Not done yet

- **Tested on a real Trixie Pi:** the changes were tested on Bookworm-like systems, the web panel on
  PHP 8.4, and the SatDump build script on Ubuntu; the first Trixie install is the first full test.
- **A 64-bit PC (amd64) on Trixie:** the bundled `predict` package for amd64 needs ncurses 5, which
  Trixie doesn't have.
