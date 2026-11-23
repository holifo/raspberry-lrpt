# What the install changes on your Pi

`./install_and_upgrade.sh` sets the Pi up as a Meteor ground station. If your Pi also does other
jobs, this page lists everything the install **removes, replaces, turns off or adds**, so you can
check it before you run it. Each line says when it happens.

## Removed or replaced

| What | When |
|---|---|
| Any other SatDump package (Debian's own `satdump` / `satdump-data`, SatDump 2.x), replaced by SatDump 1.2.3 from `software/` | Always |
| Debian's `librtlsdr0` and `rtl-sdr` packages, replaced by the RTL-SDR Blog build of the same packages (it supports the RTL-SDR Blog V4) | RTL-SDR receiver |
| An old hand-built RTL-SDR driver in `/usr/local` (`rtl_*`, `librtlsdr*`, its headers) and `/etc/udev/rules.d/rtl-sdr.rules` | RTL-SDR receiver, if present |
| nginx's `default` site, replaced by the web panel. **If it is your own site, the install asks first** (default no) and keeps a copy as `default.before-raspberry-lrpt-<date>`; no stops the install before anything changes | Always (asks only for your own site) |
| systemd's time sync (`systemd-timesyncd`) stopped and disabled, ntpsec installed instead, `/etc/ntp.conf` deleted | Only when the Pi has no chrony or openntpd: those are left alone |
| A left-over sury PHP repository entry in `/etc/apt/sources.list.d` (from raspberry-noaa-v2) | If present |
| The web panel folder `/var/www/wx-new` is mirrored from the repo: files you put there yourself are deleted | Every run |

## Kernel drivers blocked

These stop the Linux drivers from taking the receiver, so SatDump can use it. They also mean the
dongle can't be used as a TV tuner.

| What | When |
|---|---|
| `dvb_usb_rtl28xxu`, `rtl2832`, `rtl2830` (`/etc/modprobe.d/rtlsdr.conf`) | RTL-SDR receiver |
| `airspy` (`/etc/modprobe.d/airspy-blacklist.conf`) | Airspy receiver |
| `msi001`, `msi2500` blocked and unloaded (`/etc/modprobe.d/blacklist-msi.conf`) | SDRplay or MiriSDR receiver |

## Added

| What | Where |
|---|---|
| Packages: SatDump, predict, nginx, PHP-FPM, ImageMagick, ffmpeg, sox, Direwolf, Python libraries and build tools (the full list is in `ansible/roles/common/tasks/dependencies.yml`); `sstv` from pip | apt, pip |
| The receiver's own pieces: the Airspy or HackRF tools, udev rules, or SDRplay's API with its `sdrplay` service and SatDump's SDRplay plugin | Only for that receiver |
| Cron jobs: schedule passes daily at 00:01 and after a reboot, check for a new version daily, fix `/run/user` permissions after a reboot | your user's crontab |
| SatDump's rain colour table and two "Rain Likelihood" composites (setting `rain_images`; taken out again when it is off) | `/usr/share/satdump/resources/lut/cal/rl1_rain.png`, `/usr/share/satdump/satdump_cfg.json` |
| sudo rules so the web panel can remove scheduled passes, use the Meteor / ISS switches and the settings page (only those commands: `switch.sh --web …` and `settings_web.sh show` / `apply`, as the station user) | `/etc/sudoers.d/020_*`, `030_*` |
| Your user added to the `www-data` group; your home folder set to mode 755 so nginx can reach the web panel | |
| A 1000 MB RAM disk at `/var/ramfs` in `/etc/fstab` (removed again with `storage: ssd`) | SD-card systems |
| A service that switches Wi-Fi power saving off | With `disable_wifi_power_mgmt: true` |
| Logs in `/var/log/raspberry-lrpt` and their logrotate file | |
| Images and recordings in `/srv` | |
| Settings for the scripts (`~/.raspberry-lrpt.conf`), predict (`~/.predict`) and SatDump (`~/.config/satdump`: its own TLE download off and city names in green; the station position in `/usr/share/satdump/satdump_cfg.json`) | |

A first install reboots at the end, after asking (`--no-reboot` skips it).

## Not touched

- Your network protection and remote-access programs: the install doesn't check for or change them.
- chrony or openntpd, if the Pi already keeps its clock with one of them.
- Other nginx sites (any name other than `default` and `default-tls`).

## Taking it off again

`~/.rl1_utils/rl1_uninstall.sh` removes what the install added: the station's folders and
settings, its cron jobs (your other cron jobs stay), its sudo rules, and the SatDump and predict
packages. It **asks** before removing software other programs may use, and Enter keeps it:

- **the web server (nginx and PHP).** If you keep it, the web panel's site is taken out and
  your own site comes back if the install saved a copy (`default.before-raspberry-lrpt-<date>`);
  nginx is then reloaded.
- **the RTL-SDR driver package (`rtl-sdr`).**

Back up first with `~/.rl1_utils/rl1_backup_restore.sh` if you want to keep your captures.
