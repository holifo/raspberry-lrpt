# Upgrading from raspberry-noaa-v2

Raspberry-LRPT is a rework of [raspberry-noaa-v2](https://github.com/jekhokie/raspberry-noaa-v2)
for METEOR LRPT only (the NOAA APT satellites were switched off in 2025). A raspberry-noaa-v2
station can move over and keep its settings and its Meteor captures.

## What moves over

| From raspberry-noaa-v2 | To Raspberry-LRPT |
|---|---|
| Location, altitude, image location text, antenna text | the same settings |
| Receiver, Meteor gains, bias tee, frequency offsets, SDR device ids | the same settings |
| Web port, server name, TLS, admin login | the same settings (a password under 8 characters is asked again) |
| Days to schedule, days to keep images | the same settings |
| Meteor Discord webhook (when Discord posts were on) | `discord_webhook` |
| Meteor captures (database rows and images) | kept, shown on the new site |
| NOAA captures and recordings | moved to a backup folder |
| The old folder `~/raspberry-noaa-v2` | moved to the backup folder |

Everything carried over goes to `config/settings.local.yml` (not in git, readable by you only), and
the install shows it for review before it runs. Nothing is deleted: the backup folder is
`~/raspberry-noaa-v2.backup-<date>`, and you remove it when you no longer need it.

## The station already runs Bookworm or Trixie, 64-bit

Raspberry-LRPT needs Raspberry Pi OS **Bookworm or Trixie, 64-bit**. Check with
`cat /etc/os-release`. If it says bookworm or trixie and `uname -m` says aarch64 (on Trixie, build
the SatDump package first: [Trixie](trixie.md)):

```bash
cd ~ && git clone https://github.com/holifo/raspberry-lrpt raspberry-lrpt
~/raspberry-lrpt/scripts/tools/upgrade_from_noaa_v2.sh
```

It checks that no pass is being recorded or starts within 30 minutes, lists what it will do and
asks before it starts. Then it:

1. stops the old station's cron and `at` jobs
2. writes the old settings to `config/settings.local.yml`
3. copies the database, keeping the Meteor captures and taking the NOAA ones out
4. moves the NOAA images and recordings, the old folder, `~/.noaa-v2.conf` and the old logs into
   the backup folder, and offers to remove WXtoImg
5. runs `./install_and_upgrade.sh`: answer `y` to "Keep these settings?" if they look right, and
   the new questions (SD card or SSD, Discord)
6. offers to reboot, so the receiver's drivers load

`--dry-run` shows what it would do without changing anything. `-y` doesn't ask.

## An older system (Bullseye, Buster or 32-bit)

The upgrade can't happen in place: the Pi needs a fresh Bookworm or Trixie, 64-bit. Save the station to a
file first, on the old system:

```bash
cd ~ && git clone https://github.com/holifo/raspberry-lrpt raspberry-lrpt
~/raspberry-lrpt/scripts/tools/upgrade_from_noaa_v2.sh --export
```

That writes `~/noaa-v2-station-<date>.tar.gz` with the settings, the database and the Meteor
images. It holds the web admin password, so keep it private. Copy it off the Pi (a USB stick, or
`scp` to another computer), put Raspberry Pi OS Bookworm or Trixie 64-bit on the card, copy the file back to
the home folder and run:

```bash
sudo apt install git -y
cd ~ && git clone https://github.com/holifo/raspberry-lrpt raspberry-lrpt
~/raspberry-lrpt/scripts/tools/upgrade_from_noaa_v2.sh --import noaa-v2-station-<date>.tar.gz
```

## After the upgrade

- Updates: `cd ~/raspberry-lrpt && git pull && ./install_and_upgrade.sh`.
- The receivers are the same as raspberry-noaa-v2's; see [receivers.md](receivers.md). An SDRplay
  station is asked to accept SDRplay's licence during the install.
- The image lists changed: raspberry-noaa-v2's Meteor enhancement names (`MSA`, `221`, …) are
  replaced by SatDump's composite names (`MSA_corrected`, `AVHRR_221_False_Color_corrected`, …).
  Old captures still show every image they have.
