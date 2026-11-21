#!/bin/bash
#
# Turn the station's captures on or off without running the whole install.
#
#   scripts/switch.sh meteor on|off   METEOR-M2 3 and M2 4 (both together)
#   scripts/switch.sh iss on|off      the ISS SSTV extra (RTL-SDR only)
#   scripts/switch.sh                 show what is on
#   scripts/switch.sh --web …         from the web panel's switches (Admin > Passes): refused while
#                                     a pass is recording or within 2 minutes of the last change,
#                                     and the rescheduling runs in the background
#
# It saves the setting in config/settings.local.yml (so the next install keeps it), updates the
# installed copies (~/.raspberry-lrpt.conf and the web panel's Config.php) and schedules again.
# A recording already running finishes. Meteor keeps priority over the ISS.
#
# Exit codes: 0 done, 1 error, 2 a pass is recording, 3 changed too recently.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

web=0
if [ "${1:-}" == "--web" ]; then web=1; shift; fi

conf="$HOME/.raspberry-lrpt.conf"
stamp="$LRPT_HOME/tmp/switch.stamp"
config_php="$WEB_HOME/Config/Config.php"

meteor_now=$([ "$METEOR_M2_3_SCHEDULE" == "true" ] || [ "$METEOR_M2_4_SCHEDULE" == "true" ] && echo true || echo false)
iss_now=$([ "$ISS_SSTV" == "true" ] && echo true || echo false)
onoff() { [ "$1" == "true" ] && echo on || echo off; }

what="${1:-}"
state="${2:-}"
# the RTL-SDRs and which one the ISS would use (iss_sdr_device)
sdr_report() {
  local list idx mode
  list=$(python3 "$LRPT_HOME/scripts/tools/rtlsdr_list.py")
  if [ -z "$list" ]; then
    echo "RTL-SDRs: none connected (the ISS records with an RTL-SDR)"
    return
  fi
  echo "RTL-SDRs (index, maker, model, serial):"
  echo "$list" | sed 's/^/  /'
  read -r idx mode <<< "$(iss_sdr)"
  case "$mode" in
    dedicated) echo "ISS: RTL-SDR #$idx, its own - records at the same time as the Meteors" ;;
    shared)    echo "ISS: RTL-SDR #$idx, shared with the Meteors - Meteor passes come first" ;;
    *)         echo "ISS: no usable RTL-SDR" ;;
  esac
  echo "(choose another with iss_sdr_device: an index, a serial or part of the model name)"
}

if [ -z "$what" ] || [ "$what $state" == "iss " ]; then
  echo "Meteor: $(onoff "$meteor_now")   ISS SSTV: $(onoff "$iss_now")   (change with: $0 meteor|iss on|off)"
  sdr_report
  exit 0
fi
if [[ ! "$what" =~ ^(meteor|iss)$ ]] || [[ ! "$state" =~ ^(on|off)$ ]]; then
  echo "Usage: $0 [meteor|iss on|off]"
  exit 1
fi

want=$([ "$state" == "on" ] && echo true || echo false)
if [ "$what" == "iss" ] && [ "$want" == "true" ] && [ "$(iss_sdr | cut -d' ' -f2)" == "none" ]; then
  echo "The ISS records with rtl_fm and needs an RTL-SDR, and none is connected."
  exit 1
fi

if [ "$web" == "1" ]; then
  if pgrep -f "$METEOR_RUNNING" > /dev/null || pgrep -f "$ISS_RUNNING" > /dev/null; then
    echo "A pass is being recorded - try again when it ends."
    exit 2
  fi
  if [ -f "$stamp" ] && [ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -lt 120 ]; then
    echo "Changed a moment ago - try again in two minutes."
    exit 3
  fi
fi
now=$([ "$what" == "meteor" ] && echo "$meteor_now" || echo "$iss_now")
if [ "$want" == "$now" ]; then
  echo "$what is already $state."
  exit 0
fi

cd "$LRPT_HOME" || exit 1
touch "$stamp"

# save it (settings.local.yml + the merged copy), then the installed copies
if [ "$what" == "meteor" ]; then
  python3 scripts/tools/settings.py set meteor_m2_3_schedule "$state" || exit 1
  python3 scripts/tools/settings.py set meteor_m2_4_schedule "$state" || exit 1
  vars="METEOR_M2_3_SCHEDULE METEOR_M2_4_SCHEDULE"
  const="METEOR_ON"
  job="receive_meteor\.sh"
  sat="sat_name LIKE 'METEOR%'"
else
  python3 scripts/tools/settings.py set iss_sstv "$state" || exit 1
  vars="ISS_SSTV"
  const="ISS_SSTV"
  job="receive_iss\.sh"
  sat="sat_name = 'ISS'"
fi
python3 scripts/tools/settings.py merged config/.settings.merged.yml
for v in $vars; do
  sed -i "s/^${v}=.*/${v}=${want}/" "$conf"
  grep -q "^${v}=" "$conf" || echo "${v}=${want}" >> "$conf"
done
[ -f "$config_php" ] && sed -i "s/const ${const} = [a-z]*;/const ${const} = ${want};/" "$config_php"
log "$([ "$what" == "meteor" ] && echo Meteor || echo "ISS SSTV") turned ${state}$([ "$web" == "1" ] && echo " from the web panel")" "INFO"

if [ "$want" == "false" ]; then
  # drop its scheduled jobs and future passes; the other satellites' stay
  for j in $(atq | awk '{print $1}'); do
    at -c "$j" 2>/dev/null | grep -q "$job" && atrm "$j"
  done
  $SQLITE3 "$DB_FILE" "DELETE FROM predict_passes WHERE $sat AND pass_start > $(date +%s);"
  if [ "$what" == "iss" ]; then
    rm -f "$LRPT_HOME/tmp/iss.tle"
    # the web map's orbit copy without the ISS
    [ -s "$LRPT_HOME/tmp/orbit.tle" ] && cp "$LRPT_HOME/tmp/orbit.tle" "$WEB_HOME/App/Static/meteor.tle"
  fi
  echo "$([ "$what" == "meteor" ] && echo Meteor || echo "ISS SSTV") is off."
  exit 0
fi

# on: schedule everything again from now (Meteor first, then the ISS)
if [ "$web" == "1" ]; then
  # the web page shouldn't wait for the TLE download and predict
  nohup "$LRPT_HOME/scripts/schedule.sh" -t -x >> "$LRPT_LOG" 2>&1 < /dev/null &
  echo "$what is on: its passes are being scheduled."
  exit 0
fi
echo "Scheduling the passes again..."
"$LRPT_HOME/scripts/schedule.sh" -t -x
n=$($SQLITE3 "$DB_FILE" "SELECT COUNT(*) FROM predict_passes WHERE $sat AND is_active = 1 AND pass_start > $(date +%s);")
echo "$([ "$what" == "meteor" ] && echo Meteor || echo "ISS SSTV") is on: ${n:-0} passes scheduled."
