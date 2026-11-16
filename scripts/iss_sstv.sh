#!/bin/bash
#
# Turn the ISS SSTV extra on or off without running the whole install.
#
#   scripts/iss_sstv.sh on       record the ISS's SSTV pictures (RTL-SDR only)
#   scripts/iss_sstv.sh off      stop: no ISS passes, no ISS on the web panel
#   scripts/iss_sstv.sh          show whether it is on
#
# It saves iss_sstv in config/settings.local.yml (so the next install keeps it), updates the
# installed copies (~/.raspberry-lrpt.conf and the web panel's Config.php) and schedules the
# passes again. A recording already running finishes. Meteor passes are not touched.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

conf="$HOME/.raspberry-lrpt.conf"
config_php="$WEB_HOME/Config/Config.php"

case "${1:-}" in
  on|off) ;;
  "")
    echo "ISS SSTV is $([ "$ISS_SSTV" == "true" ] && echo on || echo off)  (change it with: $0 on|off)"
    exit 0 ;;
  *) echo "Usage: $0 [on|off]"; exit 1 ;;
esac

want=$([ "$1" == "on" ] && echo true || echo false)
if [ "$want" == "true" ] && [ "$RECEIVER_TYPE" != "rtlsdr" ]; then
  echo "ISS SSTV records with rtl_fm and needs an RTL-SDR (this station has ${RECEIVER_TYPE})."
  exit 1
fi

cd "$LRPT_HOME" || exit 1
python3 scripts/tools/settings.py set iss_sstv "$1" || exit 1
python3 scripts/tools/settings.py merged config/.settings.merged.yml
sed -i "s/^ISS_SSTV=.*/ISS_SSTV=${want}/" "$conf"
grep -q '^ISS_SSTV=' "$conf" || echo "ISS_SSTV=${want}" >> "$conf"
if [ -f "$config_php" ]; then
  sed -i "s/const ISS_SSTV = [a-z]*;/const ISS_SSTV = ${want};/" "$config_php"
fi
log "ISS SSTV turned $1" "INFO"

if [ "$want" == "false" ]; then
  # drop the ISS's scheduled jobs and its future passes; the Meteor ones stay
  for job in $(atq | awk '{print $1}'); do
    at -c "$job" 2>/dev/null | grep -q 'receive_iss\.sh' && atrm "$job"
  done
  $SQLITE3 "$DB_FILE" "DELETE FROM predict_passes WHERE sat_name = 'ISS' AND pass_start > $(date +%s);"
  rm -f "$LRPT_HOME/tmp/iss.tle"
  # the web map's orbit copy without the ISS
  [ -s "$LRPT_HOME/tmp/orbit.tle" ] && cp "$LRPT_HOME/tmp/orbit.tle" "$WEB_HOME/App/Static/meteor.tle"
  pgrep -f "$ISS_RUNNING" > /dev/null && echo "An ISS recording is running now; it finishes on its own."
  echo "ISS SSTV is off."
else
  # schedule again from now: Meteor passes keep priority over the ISS
  echo "Scheduling the passes again (Meteor first, then the ISS)..."
  "$LRPT_HOME/scripts/schedule.sh" -t -x
  n=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM predict_passes WHERE sat_name = 'ISS' AND is_active = 1 AND pass_start > $(date +%s);")
  echo "ISS SSTV is on: ${n:-0} ISS passes scheduled."
fi
