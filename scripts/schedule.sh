#!/bin/bash
#
# Purpose: High-level scheduling script - schedules all desired satellite
#          and orbital captures.
#
# Parameters:
#   -t: Update/re-download TLE files
#   -x: Wipe all existing future scheduled captures and start fresh
#
# Example:
#   ./schedule.sh -t -x
#
#
# Changes: 
#
# 09-Jul-2024 - AI4Y 
#    Unsetting XTERM varibles during scheduling passes, so that AT jobs are not running as XTERM envionmment which causes image annotations 
#    to fail due to : # (wkhtmltoimage:106508): Gtk-WARNING **: 19:48:38.546: cannot open display:

# import common lib and settings
. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

unset `env | egrep "WAYLAND|WAYFIRE|SESSION|TERM|GIO_|DISPLAY|GPG|QT_|SAL|XDG_" | egrep -o '^[^=]+'`
export XDG_RUNTIME_DIR=/tmp/runtime-${USER};mkdir -p -m 700 $XDG_RUNTIME_DIR

# TLE data files
WEATHER_TXT="${LRPT_HOME}/tmp/weather.txt"
TLE_OUTPUT="${LRPT_HOME}/tmp/orbit.tle"

# check if TLE file should be updated
update_tle=0
wipe_existing=0
while getopts ":tx" opt; do
  case $opt in
    # update TLE files
    t)
      update_tle=1
      ;;
    x)
      wipe_existing=1
      ;;
  esac
done

if [ "${update_tle}" == "1" ]; then
  # wait for an IP to be assigned/DNS to be available so the TLE can be retrieved
  tle_addr="www.celestrak.org"
  max_iters_sec=60
  sleep_iter_seconds=5
  counter=0
  while [ -z "${ip_addr}" ] && [ $counter -lt $max_iters_sec ]; do
    ping -c 1 $tle_addr >/dev/null
    if [ $? -eq 0 ]; then
      break
    else
      log "Scheduler waiting for DNS resolution for TLE files..." "INFO"
      ((counter+=$sleep_iter_seconds))
      sleep $sleep_iter_seconds
    fi
  done

  if [ $counter -gt 60 ]; then
    log "Scheduler failed to resolve TLE endpoint in ${counter} seconds" "ERROR"
    exit
  else
    log "Scheduler resolved TLE endpoint in ${counter} seconds" "INFO"
  fi

  # get the txt files for orbit information. CelesTrak sometimes fails (HTTP 500): the old
  # files are only replaced by a download that holds both Meteors' TLEs, because an empty
  # file leaves SatDump with no orbits (no map overlay, projections or MCIR) and nothing
  # to schedule passes from.
  log "Downloading new TLE files from source" "INFO"
  tle_tmp=$(mktemp)
  got_tle=0
  for url in "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle" \
             "http://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle"; do
    for try in 1 2 3; do
      if wget -q -T 30 "$url" -O "$tle_tmp" >> $LRPT_LOG 2>&1 && tle_file_ok "$tle_tmp"; then
        got_tle=1; break 2
      fi
      log "TLE download failed (try $try of 3): $url" "WARN"
      sleep 20
    done
  done

  if [ "$got_tle" = 1 ]; then
    mv "$tle_tmp" "${WEATHER_TXT}"
    log "Copying TLEs for SatDump" "INFO"
    cp "${WEATHER_TXT}" "/home/$TARGET_USER/.config/satdump/satdump_tles.txt" >> $LRPT_LOG 2>&1

    # create tle files for scheduling
    #   note: it's really unfortunate but a directory structure any deeper than 'tmp' in the
    #   below results in a buffer overflow reported by the predict application, presumably
    #   because it cannot handle that level of sub-directory
    log "Clearing and re-creating TLE file with latest..." "INFO"
    { grep "METEOR-M2 3" "$WEATHER_TXT" -A 2; grep "METEOR-M2 4" "$WEATHER_TXT" -A 2; } > "${TLE_OUTPUT}.new" &&
      mv "${TLE_OUTPUT}.new" "$TLE_OUTPUT"
  else
    rm -f "$tle_tmp"
    if tle_file_ok "$WEATHER_TXT"; then
      log "CelesTrak sent no valid TLEs - keeping the previous ones ($(date -r "$WEATHER_TXT" '+%d-%m-%Y %H:%M'))" "WARN"
      # put them back for SatDump too, in case its own copy was emptied
      tle_file_ok "/home/$TARGET_USER/.config/satdump/satdump_tles.txt" ||
        cp "${WEATHER_TXT}" "/home/$TARGET_USER/.config/satdump/satdump_tles.txt"
    else
      log "CelesTrak sent no valid TLEs and there are no previous ones - nothing scheduled" "ERROR"
      exit 1
    fi
  fi
elif [ ! -f $WEATHER_TXT ] || [ ! -f $TLE_OUTPUT ]; then
  log "TLE update not specified '-t' but no TLE files present - please re-run with '-t'" "INFO"
  exit 1
else
  log "Not updating local copies of TLE files from source" "INFO"
fi

# ISS SSTV (iss_sstv): the ISS's orbit is in CelesTrak's "stations" list. Its name line is
# written as plain "ISS" (CelesTrak says "ISS (ZARYA)"), so file names and predict stay simple.
# A failed download keeps the previous orbit; the ISS orbit changes with every reboost.
ISS_TLE="${LRPT_HOME}/tmp/iss.tle"
if [ "$ISS_SSTV" == "true" ] && { [ "${update_tle}" == "1" ] || [ ! -s "$ISS_TLE" ]; }; then
  iss_tmp=$(mktemp)
  if wget -q -T 30 "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle" -O "$iss_tmp" >> $LRPT_LOG 2>&1 &&
     sed -n '2p' "$iss_tmp" | grep -q '^1 25544'; then
    { echo "ISS"; sed -n '2,3p' "$iss_tmp"; } | tr -d '\r' > "$ISS_TLE"
    log "ISS orbit updated" "INFO"
  else
    log "ISS orbit download failed - keeping the previous one" "WARN"
  fi
  rm -f "$iss_tmp"
fi

# publish the TLEs for the web panel's ground-track map (Satellites tab); the ISS goes on it too
if [ -f "${TLE_OUTPUT}" ] && [ -d "${WEB_HOME}/App/Static" ]; then
  { cat "${TLE_OUTPUT}"; [ "$ISS_SSTV" == "true" ] && [ -s "$ISS_TLE" ] && cat "$ISS_TLE"; } \
    > "${WEB_HOME}/App/Static/meteor.tle" 2>> $LRPT_LOG ||
    log "Could not copy TLE file for the web panel map" "WARN"
fi

# section to remove all existing scheduled jobs/captures and clear
# all future database captures, making room for a brand new schedule
atq_date=""
if [ "${wipe_existing}" == "1" ]; then
  # remove 'at' jobs to make way for new jobs
  log "Clearing existing scheduled 'at' capture jobs..." "INFO"
  for i in $(atq | awk '{print $1}'); do
    atrm "$i"
  done

  # remove database passes for remainder of day
  cur_ms=$(date +"%s")
  log "Clearing existing passes specified in the database for remainder of the captures..." "INFO"
  $SQLITE3 $DB_FILE "DELETE FROM predict_passes WHERE pass_start > $cur_ms;"
else
  log "Determining latest scheduled capture job date..." "INFO"
  atq_date=$(atq | sort -k 6n -k 3M -k 4n -k 5 -k 7 -k 1 | awk '{print $3 " " $4 ", " $6}' | tail -1)
fi

start_time_ms=$(date +"%s")
last_day=$(($DAYS_TO_SCHEDULE_PASSES - 1))
end_time_ms=$(date --date="+${last_day} days 23:59:59" +"%s")
if [ -z "${atq_date}" ]; then
  log "No passes currently scheduled - scheduling all passes starting now through ${end_time_ms} ms..." "INFO"
else
  # calculate current day of last passes and what should be the
  # latest day of scheduled passes - assume if we've scheduled into
  # any point of the last day, we're covering all passes already
  latest_scheduled_ms=$(date --date="${atq_date} 23:59:59" +"%s")
  future_schedule_ms=$(date --date="+${last_day} days 00:00:00" +"%s")

  if [ "${latest_scheduled_ms}" -ge "${future_schedule_ms}" ]; then
    log "All passes already scheduled to latest date - nothing to be done" "INFO"
    exit
  else
    start_time_ms=$(($latest_scheduled_ms + 60))
    log "Scheduling starting at ${start_time_ms} ms through ${end_time_ms} ms..." "INFO"
  fi
fi

# create schedules to call respective receive scripts
log "Scheduling new capture jobs..." "INFO"
if [ "$METEOR_M2_3_SCHEDULE" == "true" ]; then
  log "Scheduling Meteor-M2 3 captures..." "INFO"
  $LRPT_HOME/scripts/schedule_captures.sh "METEOR-M2 3" "receive_meteor.sh" $TLE_OUTPUT $start_time_ms $end_time_ms >> $LRPT_LOG 2>&1
fi
if [ "$METEOR_M2_4_SCHEDULE" == "true" ]; then
  log "Scheduling Meteor-M2 4 captures..." "INFO"
  $LRPT_HOME/scripts/schedule_captures.sh "METEOR-M2 4" "receive_meteor.sh" $TLE_OUTPUT $start_time_ms $end_time_ms >> $LRPT_LOG 2>&1
fi
if [ "$ISS_SSTV" == "true" ]; then
  if [ "$RECEIVER_TYPE" != "rtlsdr" ]; then
    log "ISS SSTV needs an RTL-SDR (rtl_fm) - not scheduling ISS passes with ${RECEIVER_TYPE}" "WARN"
  elif [ -s "$ISS_TLE" ]; then
    log "Scheduling ISS SSTV captures..." "INFO"
    $LRPT_HOME/scripts/schedule_captures.sh "ISS" "receive_iss.sh" $ISS_TLE $start_time_ms $end_time_ms >> $LRPT_LOG 2>&1
  else
    log "No ISS orbit yet - ISS passes not scheduled" "WARN"
  fi
fi
log "Done scheduling jobs!" "INFO"

# Check if the variable is set and true
if [ "$SELECT_BEST_OVERLAPPING_PASSES" == true ]; then
    log "Program automatically selected the best pass!" "INFO"
    $LRPT_HOME/scripts/select_best_overlapping_passes.py $DB_FILE true
else
    log "You should manually remove overlapping passes." "INFO"
fi
