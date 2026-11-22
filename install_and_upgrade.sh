#!/bin/bash
#
# Install or upgrade a Raspberry-LRPT Meteor station.
# Run from ~/raspberry-lrpt as the normal user (not with sudo):
#   cd ~/raspberry-lrpt && git pull && ./install_and_upgrade.sh
#
# Options:
#   -y, --yes        don't ask: wait for a running capture, reboot after a first install
#   --no-reboot      never reboot at the end (a first install then needs a manual reboot)
#   -h, --help       show this help
#
# Everything is also written to ~/raspberry-lrpt/install.log.

REPO="$HOME/raspberry-lrpt"
LOG="$REPO/install.log"
ASSUME_YES=false
NO_REBOOT=false

# ---- output helpers -------------------------------------------------------------
if [ -t 1 ]; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); DIM=$(tput dim); BOLD=$(tput bold); RESET=$(tput sgr0)
fi
STEP=0
STEPS=7
START=$(date +%s)

LOGGING=false
die()  { >&2 echo "${RED}✗ Error: $1${RESET}"; $LOGGING && >&2 echo "  ${DIM}Full output: $LOG${RESET}"; exit 1; }
warn() { echo " ${YELLOW}! $1${RESET}"; }
step() { STEP=$((STEP + 1)); echo ""; echo "${BOLD}[$STEP/$STEPS] $1${RESET}"; }
ok()   { echo " ${GREEN}✓ $1${RESET}"; }
ask()  { $ASSUME_YES && return 0; local a; read -r -p " $1 [Y/n] " a < /dev/tty; [[ -z "$a" || "$a" =~ ^[Yy] ]]; }

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)    ASSUME_YES=true ;;
    --no-reboot) NO_REBOOT=true ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ---- checks before touching anything ---------------------------------------------
[ $EUID -eq 0 ] && die "Don't run this with sudo; run it as your normal user"
[ -d "$REPO/.git" ] || die "The repository must be cloned to ~/raspberry-lrpt"
cd "$REPO" || die "Can't change to $REPO"

# only one install at a time
exec 9>"/tmp/rl1-install.lock"
if ! flock -n 9; then
  holder=$(fuser /tmp/rl1-install.lock 2>/dev/null | tr -s " " "\n" | grep -vx "$$" | grep . | xargs -r ps -o pid=,etime=,args= -p 2>/dev/null)
  die "Another install is already running${holder:+:
$holder}"
fi

# everything from here on also goes to the log file
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
LOGGING=true

echo "${BOLD}Raspberry-LRPT - install/upgrade v$(cat VERSION 2>/dev/null || echo '?') ($(git rev-parse --short HEAD 2>/dev/null))${RESET}"
echo "${DIM}$(date '+%d/%m/%Y %H:%M:%S') · log: $LOG${RESET}"

step "Checking the system"

codename=$(. /etc/os-release && echo "${DEBIAN_CODENAME:-$VERSION_CODENAME}")  # Debian-based (LMDE "gigi" = trixie)
case "$codename" in
  bookworm|trixie) ;;
  *) die "This station needs Raspberry Pi OS / Debian Bookworm or Trixie (found: ${codename:-unknown})" ;;
esac
arch=$(dpkg --print-architecture)
case "$arch" in arm64|armhf|amd64) ;; *) die "Unsupported architecture: $arch" ;; esac
satdump_deb=$(ls software/satdump_*_"${codename}"_"${arch}".deb 2>/dev/null | head -1)
[ -n "$satdump_deb" ] || die "No SatDump package for ${codename} ${arch} in software/.
      Build it once on this Pi with scripts/tools/build_satdump_deb.sh (about an hour), then run this again."
ok "OS: ${codename^} ($arch)"

free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
[ "$free_mb" -lt 1024 ] && die "Only ${free_mb} MB free on / - free at least 1 GB first"
[ "$free_mb" -lt 3072 ] && warn "Only ${free_mb} MB free on / (3 GB or more is better for captures)"
ok "Disk: ${free_mb} MB free"

getent hosts deb.debian.org >/dev/null || die "No internet/DNS - apt and the orbit download need it"
ok "Internet: OK"

# sudo once now, so the steps below don't stop half-way for a password
sudo -v || die "This script needs sudo rights"
# (9>&-: the loop must not hold the install lock after the install ends)
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 50; done ) >/dev/null 2>&1 9>&- &

# local changes to tracked files block the next "git pull"
changed=$(git status --porcelain --untracked-files=no)
if [ -n "$changed" ]; then
  warn "These repo files were changed on this Pi (the next 'git pull' may refuse to run):"
  echo "$changed" | sed 's/^/     /'
  warn "Undo with: git checkout -- <file>"
fi

# don't restart services or swap libraries in the middle of a pass
if pgrep -f "satdump live" >/dev/null; then
  warn "A pass is being recorded right now."
  if ask "Wait for it to finish before installing?"; then
    echo -n "   waiting"
    while pgrep -f "satdump live" >/dev/null; do echo -n "."; sleep 15; done
    echo " done"
  else
    die "Stopped - run the install again after the pass"
  fi
fi

# a first install reboots at the end; the station's shell settings (or, on stations from before
# v1.23.0 and raspberry-noaa-v2 ones, the RTL-SDR modprobe config) mark an existing install
install_type='install'
{ [ -f "$HOME/.raspberry-lrpt.conf" ] || [ -f /etc/modprobe.d/rtlsdr.conf ]; } && install_type='upgrade'
ok "Mode: $install_type"

step "Station settings"
sudo apt-get install -qq -y python3-yaml python3-jsonschema >/dev/null \
  || die "Could not install the Python modules needed to check the settings"
# answers to the setup questions live in config/settings.local.yml (not in git), over settings.yml
if [ -f config/settings.local.yml ] || [ "$install_type" == "upgrade" ]; then
  # questions added since this station was set up (e.g. SD card or SSD) are asked once
  $ASSUME_YES || python3 scripts/tools/settings.py ask-new || die "Setup questions stopped"
  python3 scripts/tools/settings.py summary
  if $ASSUME_YES; then
    ok "Keeping these settings"
  elif ask "Keep these settings?"; then
    ok "Keeping these settings"
  else
    python3 scripts/tools/settings.py setup || die "Setup questions stopped"
  fi
elif $ASSUME_YES; then
  warn "First install with -y: using config/settings.yml as it is"
else
  echo " First install: a few questions about your station (Enter keeps the value shown)."
  python3 scripts/tools/settings.py setup || die "Setup questions stopped"
fi
python3 scripts/tools/settings.py merged config/.settings.merged.yml || die "Could not merge the settings"
python3 scripts/tools/validate_yaml.py config/.settings.merged.yml config/settings_schema.json \
  || die "Please fix config/settings.yml or config/settings.local.yml (see the errors above)"
ok "Settings OK"

step "Preparing Ansible"
if ! command -v ansible-playbook >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -qq -y ansible >/dev/null || die "Could not install Ansible"
fi
ok "$(ansible --version | head -1)"

step "Running Ansible (packages, SatDump, settings, web server)"
echo "   ${DIM}a few minutes on an upgrade, much longer on a first install${RESET}"
# compact output (ansible/callback_plugins/compact.py): one line per part, the tasks that changed
# something under it, and details only when a task fails
ANSIBLE_STDOUT_CALLBACK=compact ANSIBLE_CALLBACK_PLUGINS="$REPO/ansible/callback_plugins" \
ANSIBLE_PYTHON_INTERPRETER=auto_silent ANSIBLE_DEPRECATION_WARNINGS=false ANSIBLE_LOCALHOST_WARNING=false \
ansible-playbook -i ansible/hosts --extra-vars "@config/.settings.merged.yml" ansible/site.yml \
  -e "target_user=$USER system_architecture=$arch" \
  || die "Ansible failed - see the task marked ✗ above"
ok "Ansible complete"

. "$HOME/.raspberry-lrpt.conf"

step "Updating the database"
"$LRPT_HOME/db_migrations/update_database.sh" || die "Database update failed"
ok "Database schema up to date"

step "Updating the web panel"
# mirror webpanel/ into the web root; keep the generated Config.php, the composer
# packages and the map's orbit file, which are not in the repo
rsync -a --delete --exclude /Config/ --exclude /vendor/ --exclude /App/Static/meteor.tle \
  "$LRPT_HOME"/webpanel/ "$WEB_HOME"/ || die "Copying the web panel failed"
cp -f "$LRPT_HOME"/VERSION "$WEB_HOME"/VERSION || die "Copying VERSION failed"   # shown in the footer
sudo chown -R "$USER":www-data "$WEB_HOME"/ || die "Setting web panel ownership failed"
composer install -q --no-interaction -d "$WEB_HOME"/ || die "composer install failed"
if [ "$ENABLE_NON_TLS" = true ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${WEBPANEL_PORT}/passes")
  if [ "$code" = "200" ]; then ok "Web panel answers (HTTP 200)"; else warn "Web panel returned HTTP $code - check nginx and PHP"; fi
else
  ok "Web panel updated"
fi

step "Scheduling passes"
# reuse today's orbit data (CelesTrak limits repeat downloads); download it on a first run
sched_opt=""
# download TLEs when there are none, or the last download left them empty or broken
grep -q '^1 57166' "$LRPT_HOME/tmp/orbit.tle" 2>/dev/null && grep -q '^1 59051' "$LRPT_HOME/tmp/orbit.tle" &&
  grep -q '^1 59051' "$LRPT_HOME/tmp/weather.txt" 2>/dev/null || sched_opt="-t"
if ./scripts/schedule.sh $sched_opt; then ok "Passes scheduled"; else warn "The scheduler reported a problem - see $LRPT_LOG"; fi
# the About page's update status (git fetch only; daily from cron too)
./scripts/update_check.sh >/dev/null 2>&1 || true

# ---- summary ------------------------------------------------------------------------
svc() { systemctl is-active --quiet "$1" && echo "${GREEN}$1${RESET}" || echo "${RED}$1 (stopped)${RESET}"; }
next=$(sqlite3 "$DB_FILE" "SELECT sat_name || ' at ' || strftime('%d/%m %H:%M', pass_start, 'unixepoch', 'localtime')
                                   || ', max ' || max_elev || '°'
                            FROM predict_passes WHERE pass_start > strftime('%s','now') AND is_active = 1
                            ORDER BY pass_start LIMIT 1;" 2>/dev/null)
# the station's receiver on USB (receiver_type in the settings)
receiver=$(grep -E "^RECEIVER_TYPE=" "$HOME/.raspberry-lrpt.conf" 2>/dev/null | cut -d= -f2 | tr -d "'\"")
case "$receiver" in
  airspy_mini|airspy_r2)    usb_id="1d50:60a1";          sdr_name="Airspy" ;;
  airspy_hf_plus_discovery) usb_id="03eb:800c";          sdr_name="Airspy HF+" ;;
  hackrf)                   usb_id="1d50:6089|1d50:cc15"; sdr_name="HackRF" ;;
  sdrplay|mirisdr)          usb_id="1df7:|2040:d300";    sdr_name="Mirics/SDRplay" ;;
  *)                        usb_id="RTL28|0bda:28";      sdr_name="RTL-SDR" ;;
esac
sdr=$(lsusb 2>/dev/null | grep -iE "$usb_id" | head -1)
secs=$(( $(date +%s) - START ))

echo ""
echo "${BOLD}${GREEN}✓ Install/upgrade complete${RESET} in $((secs / 60)) min $((secs % 60)) s"
echo "   Web panel : http://$(hostname -I | awk '{print $1}'):${WEBPANEL_PORT}   (public name: ${WEB_SERVER_NAME})"
echo "   Next pass : ${next:-none scheduled}"
if [ -n "$sdr" ]; then echo "   SDR       : ${GREEN}found${RESET} ${DIM}${sdr#*ID }${RESET}"
else echo "   SDR       : ${YELLOW}no ${sdr_name} found on USB${RESET}"; fi
php_fpm=$(systemctl list-unit-files --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | sort -V | tail -1)
php_fpm=${php_fpm%.service}
[ "$receiver" == "sdrplay" ] && sdrplay_svc=" $(svc sdrplay)"
# the time service: ntpsec, or the Pi's own chrony / openntpd, which the install leaves alone
timed=ntpsec
for t in chrony openntpd; do systemctl list-unit-files --no-legend "$t.service" 2>/dev/null | grep -q . && timed=$t && break; done
echo "   Services  : $(svc nginx) $(svc "${php_fpm:-php-fpm}") $(svc atd) $(svc $timed)${sdrplay_svc}"
echo "   Log       : $LOG"

if [ "$install_type" == 'install' ]; then
  echo ""
  echo " ${YELLOW}* First install: reloading the SDR udev rules and running the checks${RESET}"
  sudo udevadm control --reload-rules && sudo udevadm trigger
  scripts/tools/verification_tool/verification.sh quick
  if $NO_REBOOT; then
    warn "Reboot before the first pass so the SDR drivers load: sudo reboot"
  elif ask "Reboot now (needed after a first install)?"; then
    sudo reboot
  else
    warn "Reboot before the first pass: sudo reboot"
  fi
fi
