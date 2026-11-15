#!/bin/bash
#
# Upgrades a raspberry-noaa-v2 station to Raspberry-LRPT. Run it from a fresh clone in
# ~/raspberry-lrpt, as the normal user:
#
#   cd ~ && git clone https://github.com/holifo/raspberry-lrpt raspberry-lrpt
#   ~/raspberry-lrpt/scripts/tools/upgrade_from_noaa_v2.sh
#
# What it does:
#   - stops the old station's cron and 'at' jobs (it waits for no pass to be close)
#   - carries the old settings over into config/settings.local.yml: location, receiver, gains,
#     bias tee, web port and login, and the Meteor Discord webhook if Discord posts were on
#   - keeps the Meteor captures: the database (its NOAA rows taken out) and their images
#   - moves the NOAA images and the old folder into ~/raspberry-noaa-v2.backup-<date>
#     (nothing is deleted; remove that folder yourself when you no longer need it)
#   - runs install_and_upgrade.sh, which shows the settings for review and asks the new questions
#
# Raspberry-LRPT needs Raspberry Pi OS Bookworm or Trixie, 64-bit. On an older system (Bullseye,
# Buster or 32-bit) save the station to a file, put Bookworm or Trixie on the Pi, clone and import it:
#   upgrade_from_noaa_v2.sh --export      writes ~/noaa-v2-station-<date>.tar.gz
#   upgrade_from_noaa_v2.sh --import FILE on the new system, from ~/raspberry-lrpt
#
# Options: -y (don't ask), --dry-run (show what would happen), --old DIR (another old folder),
#          --keep-wxtoimg (leave WXtoImg installed)

NEW="$(cd "$(dirname "$0")/../.." && pwd)"
OLD="$HOME/raspberry-noaa-v2"
STAMP=$(date '+%Y%m%d-%H%M')
BACKUP="$HOME/raspberry-noaa-v2.backup-$STAMP"
IMAGES=/srv/images
MODE=upgrade
ASSUME_YES=false
DRY=false
KEEP_WXTOIMG=false
IMPORT_FILE=""

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)       ASSUME_YES=true ;;
    --dry-run)      DRY=true ;;
    --export)       MODE=export ;;
    --import)       MODE=import; IMPORT_FILE=$2; shift ;;
    --old)          OLD=$2; shift ;;
    --keep-wxtoimg) KEEP_WXTOIMG=true ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=; G=; Y=; R=; N=; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "  ${G}ok${N}  $*"; }
warn() { echo "  ${Y}!!${N}  $*"; }
die()  { echo "  ${R}xx${N}  $*" >&2; exit 1; }
run()  { if $DRY; then echo "  would run: $*"; else "$@"; fi; }
ask()  { $ASSUME_YES && return 0; local a; read -r -p "  $1 [y/N] " a < /dev/tty; [[ "$a" =~ ^[Yy] ]]; }
helper() { python3 "$NEW/scripts/tools/noaa_v2_import.py" "$@"; }

# files of a capture: its images and thumbnails (BASE-*.jpg/png and thumb/BASE-*)
capture_files() {
  local base=$1
  ls -d "$IMAGES/$base"-* "$IMAGES/thumb/$base"-* 2>/dev/null
}

[ $EUID -eq 0 ] && die "Run it as your normal user, not with sudo"
command -v python3 >/dev/null || die "python3 is needed"
python3 -c 'import yaml' 2>/dev/null || { sudo apt-get install -qq -y python3-yaml >/dev/null || die "Could not install python3-yaml"; }

# ---- export: save the old station to a file (any OS) -------------------------------------
if [ "$MODE" == "export" ]; then
  step "Saving the raspberry-noaa-v2 station to a file"
  [ -f "$OLD/config/settings.yml" ] || die "$OLD/config/settings.yml not found (use --old DIR)"
  out="$HOME/noaa-v2-station-$STAMP.tar.gz"
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/station/images"
  cp "$OLD/config/settings.yml" "$work/station/settings.yml"
  if [ -f "$OLD/db/panel.db" ]; then
    cp "$OLD/db/panel.db" "$work/station/panel.db"
    n=0
    while read -r base; do
      while read -r f; do
        rel=${f#$IMAGES/}; mkdir -p "$work/station/images/$(dirname "$rel")"
        cp -p "$f" "$work/station/images/$rel"
      done < <(capture_files "$base")
      n=$((n + 1))
    done < <(helper bases "$work/station/panel.db" meteor)
    ok "$n Meteor captures"
  else
    warn "No database at $OLD/db/panel.db: only the settings are saved"
  fi
  run tar -czf "$out" -C "$work" station
  chmod 600 "$out" 2>/dev/null
  ok "Saved to $out ($(du -h "$out" 2>/dev/null | cut -f1))"
  echo
  echo "  It holds your settings, including the web admin password: keep it private."
  echo "  Copy it off the Pi, install Raspberry Pi OS Bookworm or Trixie 64-bit, then:"
  echo "    cd ~ && git clone https://github.com/holifo/raspberry-lrpt raspberry-lrpt"
  echo "    ~/raspberry-lrpt/scripts/tools/upgrade_from_noaa_v2.sh --import $(basename "$out")"
  exit 0
fi

# ---- checks --------------------------------------------------------------------------------
step "Checks"
[ "$NEW" == "$HOME/raspberry-lrpt" ] || die "Run this from the clone in ~/raspberry-lrpt (it is in $NEW)"
codename=$(. /etc/os-release 2>/dev/null; echo "$VERSION_CODENAME")
if [ "$codename" != "bookworm" ] && [ "$codename" != "trixie" ]; then
  die "Raspberry-LRPT needs Raspberry Pi OS Bookworm or Trixie, 64-bit (this is ${codename:-unknown}).
      Save the station first:  $0 --export
      then install Bookworm or Trixie and run this with --import FILE."
fi
ok "Raspberry Pi OS $codename"

if [ "$MODE" == "import" ]; then
  [ -f "$IMPORT_FILE" ] || die "$IMPORT_FILE not found"
  SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT
  tar -xzf "$IMPORT_FILE" -C "$SRC" || die "Can't read $IMPORT_FILE"
  OLD_SETTINGS="$SRC/station/settings.yml"
  OLD_DB="$SRC/station/panel.db"
  [ -f "$OLD_SETTINGS" ] || die "$IMPORT_FILE has no settings.yml (made with --export?)"
  ok "Station file $IMPORT_FILE"
else
  [ -d "$OLD" ] || die "$OLD not found (use --old DIR, or --import FILE for a saved station)"
  OLD_SETTINGS="$OLD/config/settings.yml"
  OLD_DB="$OLD/db/panel.db"
  [ -f "$OLD_SETTINGS" ] || die "$OLD_SETTINGS not found"
  ok "Old station in $OLD"
  pgrep -f "satdump live|receive_noaa|receive_meteor|rtl_fm|wxtoimg" >/dev/null \
    && die "A pass is being recorded now - run this again when it has finished"
  if [ -f "$OLD_DB" ]; then
    now=$(date +%s)
    next=$(python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('SELECT MIN(pass_start) FROM predict_passes WHERE is_active = 1 AND pass_start > ?', (int(sys.argv[2]),)).fetchone()[0] or '')" "$OLD_DB" "$now" 2>/dev/null)
    if [ -n "$next" ] && [ $((next - now)) -lt 1800 ]; then
      die "The next pass starts at $(date -d "@$next" '+%H:%M') - run this again after it"
    fi
  fi
fi
[ -f "$NEW/config/settings.local.yml" ] && warn "config/settings.local.yml exists: its answers win over the old settings"
if [ -f "$NEW/db/panel.db" ] && [ -s "$NEW/db/panel.db" ]; then
  die "$NEW/db/panel.db already exists: this is for a fresh clone (move it aside to continue)"
fi

meteor=0 noaa=0
if [ -f "$OLD_DB" ]; then
  meteor=$(helper bases "$OLD_DB" meteor | wc -l)
  noaa=$(helper bases "$OLD_DB" other | wc -l)
fi
echo
echo "  This will:"
[ "$MODE" == "upgrade" ] && echo "   - stop the old station's scheduled jobs"
echo "   - carry its settings over to $NEW/config/settings.local.yml"
echo "   - keep its $meteor Meteor captures"
[ "$MODE" == "upgrade" ] && echo "   - move $noaa NOAA captures and $OLD into $BACKUP"
echo "   - run the Raspberry-LRPT install (you review the settings there)"
ask "Go ahead?" || die "Stopped, nothing changed"
$DRY || sudo -v || die "sudo is needed"

# ---- old jobs --------------------------------------------------------------------------------
if [ "$MODE" == "upgrade" ]; then
  step "Stopping the old station's jobs"
  if crontab -l 2>/dev/null | grep -q "raspberry-noaa-v2"; then
    if $DRY; then
      echo "  would remove these crontab lines:"; crontab -l | grep "raspberry-noaa-v2" | sed 's/^/      /'
    else
      # drop each old job and the "#Ansible: name" line above it
      crontab -l | python3 -c '
import sys
lines = sys.stdin.read().splitlines()
out = []
for line in lines:
    if "raspberry-noaa-v2" in line:
        if out and out[-1].startswith("#Ansible:"):
            out.pop()
        continue
    out.append(line)
print("\n".join(out))' | crontab - && ok "Old cron jobs removed"
    fi
  fi
  old_jobs=$(for j in $(atq | awk '{print $1}'); do at -c "$j" 2>/dev/null | grep -q "raspberry-noaa-v2" && echo "$j"; done)
  if [ -n "$old_jobs" ]; then
    for j in $old_jobs; do run atrm "$j"; done
    ok "$(echo "$old_jobs" | wc -w) old capture jobs removed"
  fi
fi

# ---- settings ----------------------------------------------------------------------------------
step "Settings"
if $DRY; then
  tmp=$(mktemp -d)
  cp "$NEW/config/settings.local.yml" "$tmp/local.yml" 2>/dev/null
  helper settings "$OLD_SETTINGS" "$tmp/local.yml"
  rm -rf "$tmp"
  echo "  (would be written to config/settings.local.yml)"
else
  helper settings "$OLD_SETTINGS" "$NEW/config/settings.local.yml" || die "Could not read $OLD_SETTINGS"
  ok "Written to config/settings.local.yml (not in git, readable by you only)"
fi

# ---- captures --------------------------------------------------------------------------------
step "Captures"
if [ -f "$OLD_DB" ]; then
  if $DRY; then
    echo "  would copy the database, keep $meteor Meteor captures and take out $noaa NOAA ones"
  else
    mkdir -p "$NEW/db"
    cp "$OLD_DB" "$NEW/db/panel.db"
    read -r kept removed passes < <(helper prune "$NEW/db/panel.db")
    ok "Database: $kept Meteor captures kept, $removed other captures and $passes NOAA passes taken out"
  fi
  if [ "$MODE" == "upgrade" ] && [ "$noaa" -gt 0 ]; then
    run mkdir -p "$BACKUP/noaa-images/thumb"
    moved=0
    while read -r base; do
      while read -r f; do
        rel=${f#$IMAGES/}
        run mv "$f" "$BACKUP/noaa-images/$rel" && moved=$((moved + 1))
      done < <(capture_files "$base")
    done < <(helper bases "$OLD_DB" other)
    ok "$moved NOAA image files moved to $BACKUP/noaa-images"
  fi
else
  warn "No old database: starting with an empty capture list"
fi

# ---- the old station's folder and leftovers -------------------------------------------------
if [ "$MODE" == "upgrade" ]; then
  step "Old station"
  run mkdir -p "$BACKUP"
  run mv "$OLD" "$BACKUP/raspberry-noaa-v2" && ok "$OLD -> $BACKUP/raspberry-noaa-v2"
  [ -f "$HOME/.noaa-v2.conf" ] && run mv "$HOME/.noaa-v2.conf" "$BACKUP/" && ok "~/.noaa-v2.conf moved there too"
  [ -d /srv/audio/noaa ] && run sudo mv /srv/audio/noaa "$BACKUP/noaa-audio" && ok "NOAA recordings moved there too"
  run sudo rm -f /etc/logrotate.d/raspberry-noaa-v2
  if [ -d /var/log/raspberry-noaa-v2 ]; then
    run sudo mv /var/log/raspberry-noaa-v2 "$BACKUP/old-logs" && run sudo chown -R "$USER" "$BACKUP/old-logs"
  fi
  if ! $KEEP_WXTOIMG && dpkg -s wxtoimg >/dev/null 2>&1; then
    if ask "Remove WXtoImg (NOAA only, not used any more)?"; then
      run sudo apt-get purge -qq -y wxtoimg >/dev/null && run rm -f "$HOME/.wxtoimgrc" "$HOME/.wxtoimglic" && ok "WXtoImg removed"
    fi
  fi
fi

# ---- install --------------------------------------------------------------------------------------
step "Raspberry-LRPT install"
if $DRY; then
  echo "  would run: $NEW/install_and_upgrade.sh --no-reboot"
  echo; echo "${B}Dry run finished - nothing was changed.${N}"
  exit 0
fi
cd "$NEW" || die "Can't change to $NEW"
./install_and_upgrade.sh --no-reboot || die "The install stopped - see $NEW/install.log, fix the problem and run ./install_and_upgrade.sh"

# an imported station's images go in once the install has made /srv/images
if [ "$MODE" == "import" ] && [ -d "$SRC/station/images" ]; then
  step "Imported images"
  cp -rp "$SRC/station/images/." "$IMAGES/" && ok "$(find "$SRC/station/images" -type f | wc -l) image files copied to $IMAGES"
fi

echo
echo "${B}${G}Done.${N} The station now runs Raspberry-LRPT from $NEW."
[ "$MODE" == "upgrade" ] && echo "  The old station is in $BACKUP; delete it when you no longer need it."
echo "  Updates from now on:  cd ~/raspberry-lrpt && git pull && ./install_and_upgrade.sh"
if ! $ASSUME_YES && ask "Reboot now so the receiver's drivers load?"; then
  sudo reboot
else
  echo "  Reboot before the next pass so the receiver's drivers load: sudo reboot"
fi
