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
  # wait (at most a minute, e.g. just after a boot) until a TLE source's name resolves. This only
  # checks DNS: ping is blocked on many networks and CelesTrak is unreachable from some, which
  # used to cost a minute of "waiting for DNS" lines before every update.
  waited=0
  until getent hosts celestrak.org >/dev/null || getent hosts tle.ivanstanojevic.me >/dev/null ||
        getent hosts www.amsat.org >/dev/null || getent hosts db.satnogs.org >/dev/null; do
    if [ $waited -ge 60 ]; then
      log "No DNS for any TLE source after ${waited} s - trying the downloads anyway" "WARN"
      break
    fi
    [ $waited -eq 0 ] && log "Waiting for DNS before downloading TLEs (up to 60 s)..." "INFO"
    sleep 5; ((waited+=5))
  done
  [ $waited -gt 0 ] && [ $waited -lt 60 ] && log "DNS ready after ${waited} s" "INFO"

  # get the txt files for orbit information. CelesTrak sometimes fails (HTTP 500): the old
  # files are only replaced by a download that holds both Meteors' TLEs, because an empty
  # file leaves SatDump with no orbits (no map overlay, projections or MCIR) and nothing
  # to schedule passes from.
  log "Downloading new TLE files from source" "INFO"
  tle_tmp=$(mktemp)
  got_tle=0
  # CelesTrak: two tries over https (it sometimes answers HTTP 500 for a moment), one over http;
  # then the backups in the owner's order: TLE API, AMSAT, SatNOGS DB (backup_tle.py).
  # -t 1: wget's own retries would multiply the wait when a site is unreachable.
  for url in "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle" \
             "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle" \
             "http://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle"; do
    if wget -q -t 1 -T 20 "$url" -O "$tle_tmp" >> $LRPT_LOG 2>&1 && tle_file_ok "$tle_tmp"; then
      got_tle=1; break
    fi
    log "TLE download from CelesTrak failed: $url" "WARN"
    sleep 5
  done
  # backups when CelesTrak can't be reached: TLE API, then AMSAT, then the SatNOGS DB
  if [ "$got_tle" = 0 ]; then
    for src in tleapi amsat satnogs; do
      if python3 "$LRPT_HOME/scripts/tools/backup_tle.py" $src "$tle_tmp" 57166="METEOR-M2 3" 59051="METEOR-M2 4" >> $LRPT_LOG 2>&1 &&
         tle_file_ok "$tle_tmp"; then
        got_tle=1
        log "CelesTrak failed - TLEs from $(tle_source_name $src) instead" "WARN"
        break
      fi
      log "TLE backup $(tle_source_name $src) failed" "WARN"
    done
  fi

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
      log "No TLE source sent valid TLEs - keeping the previous ones ($(date -r "$WEATHER_TXT" '+%d-%m-%Y %H:%M'))" "WARN"
      # put them back for SatDump too, in case its own copy was emptied
      tle_file_ok "/home/$TARGET_USER/.config/satdump/satdump_tles.txt" ||
        cp "${WEATHER_TXT}" "/home/$TARGET_USER/.config/satdump/satdump_tles.txt"
    else
      log "No TLE source sent valid TLEs and there are no previous ones - nothing scheduled" "ERROR"
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
  if wget -q -t 1 -T 20 "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle" -O "$iss_tmp" >> $LRPT_LOG 2>&1 &&
     sed -n '2p' "$iss_tmp" | grep -q '^1 25544'; then
    { echo "ISS"; sed -n '2,3p' "$iss_tmp"; } | tr -d '\r' > "$ISS_TLE"
    log "ISS orbit updated" "INFO"
  else
    iss_ok=0
    for src in tleapi amsat satnogs; do
      if python3 "$LRPT_HOME/scripts/tools/backup_tle.py" $src "$iss_tmp" 25544="ISS" >> $LRPT_LOG 2>&1 &&
         sed -n '2p' "$iss_tmp" | grep -q '^1 25544'; then
        tr -d '\r' < "$iss_tmp" > "$ISS_TLE"
        log "ISS orbit from $(tle_source_name $src) (CelesTrak failed)" "WARN"
        iss_ok=1; break
      fi
    done
    [ "$iss_ok" = 1 ] || log "ISS orbit download failed everywhere - keeping the previous one" "WARN"
  fi
  rm -f "$iss_tmp"
fi

# publish the TLEs for the web panel's ground-track map (Satellites tab); the ISS goes on it too
if [ -f "${TLE_OUTPUT}" ] && [ -d "${WEB_HOME}/App/Static" ]; then
  # (the ISS test is an if: as "[ … ] && cat" it ended the group with "false" whenever the ISS
  # was off, and that was logged as a failed copy although the file was written)
  { cat "${TLE_OUTPUT}"; if [ "$ISS_SSTV" == "true" ] && [ -s "$ISS_TLE" ]; then cat "$ISS_TLE"; fi; } \
    > "${WEB_HOME}/App/Static/meteor.tle" 2>> $LRPT_LOG ||
    log "Could not copy TLE file for the web panel map" "WARN"
fi

# the RTL-SDRs and what each records, for the web panel's Live log (sdr_roles, common.sh), and
# the ISS's dongle for the Passes pages. Written before the "all passes already scheduled" exit
# below, so a re-install or a dongle swap updates them too.
sdr_roles > "${IMAGE_OUTPUT}/sdr.json.tmp" 2>/dev/null && mv "${IMAGE_OUTPUT}/sdr.json.tmp" "${IMAGE_OUTPUT}/sdr.json"
if [ "$ISS_SSTV" == "true" ]; then
  read -r iss_idx iss_mode <<< "$(iss_sdr)"
  printf '{"index": "%s", "mode": "%s", "made": %s}\n' "$iss_idx" "$iss_mode" "$(date +%s)" > "${IMAGE_OUTPUT}/iss-sdr.json" 2>/dev/null
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
iss_own_sdr=false
if [ "$ISS_SSTV" == "true" ]; then
  if [ "$iss_mode" == "none" ]; then
    log "The ISS records with an RTL-SDR (rtl_fm) and none is connected - not scheduling ISS passes" "WARN"
  elif [ -s "$ISS_TLE" ]; then
    if [ "$iss_mode" == "dedicated" ]; then
      iss_own_sdr=true
      log "Scheduling ISS captures on RTL-SDR #${iss_idx} (its own: alongside the Meteor passes)..." "INFO"
    else
      log "Scheduling ISS captures on the Meteors' RTL-SDR (Meteor passes come first)..." "INFO"
    fi
    $LRPT_HOME/scripts/schedule_captures.sh "ISS" "receive_iss.sh" $ISS_TLE $start_time_ms $end_time_ms >> $LRPT_LOG 2>&1
  else
    log "No ISS orbit yet - ISS passes not scheduled" "WARN"
  fi
fi
log "Done scheduling jobs!" "INFO"

# Check if the variable is set and true
if [ "$SELECT_BEST_OVERLAPPING_PASSES" == true ]; then
    log "Program automatically selected the best pass!" "INFO"
    $LRPT_HOME/scripts/select_best_overlapping_passes.py $DB_FILE true $iss_own_sdr
else
    log "You should manually remove overlapping passes." "INFO"
fi
