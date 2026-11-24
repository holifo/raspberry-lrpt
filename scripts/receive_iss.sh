#!/bin/bash
#
# Purpose: Record an ISS pass on iss_sstv_frequency (437.550 or 145.800 MHz FM) and decode the SSTV
#          pictures (Robot 36, PD120, …) the ISS sends
#          during ARISS events (iss_sstv in settings.yml). Scheduled like the Meteor passes
#          (schedule_captures.sh), with the same arguments:
#
#   1. satellite name ("ISS")   2. file name base   3. TLE file   4. start (epoch)
#   5. capture time (s)         6. max elevation    7. direction  8. side of pass
#
# A pass with no pictures (most of the year) leaves nothing behind: its scheduled row is
# removed, so the site doesn't list it as a missed pass.
#
# APRS (iss_aprs): outside an SSTV event's dates (iss_sstv_dates; every pass when it is empty)
# it records the ISS's APRS digipeater (iss_aprs_frequency) instead and decodes it live with direwolf.
# The packets go to $IMAGE_OUTPUT/aprs-live.csv while the pass lasts (the Satellites map shows
# them), then to the pass's -aprs.json and -aprs-map.png (sat_type 4).

TIMER_START=$(date '+%s')

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

export SAT_NAME=$1
export FILENAME_BASE=$2
export TLE_FILE=$3
export EPOCH_START=$4
export CAPTURE_TIME=$5
export SAT_MAX_ELEVATION=$6
export PASS_DIRECTION=$7
export PASS_SIDE=$8

IMAGE_FILE_BASE="${IMAGE_OUTPUT}/${FILENAME_BASE}"
IMAGE_THUMB_BASE="${IMAGE_OUTPUT}/thumb/${FILENAME_BASE}"
AUDIO_FILE_BASE="${METEOR_AUDIO_OUTPUT}/${FILENAME_BASE}"
RATE=11025

# which RTL-SDR (iss_sdr_device): its own dongle records alongside the Meteors; the Meteors' one
# (a station with one RTL-SDR) is shared, and then Meteor passes come first
read -r SDR_INDEX SDR_MODE <<< "$(iss_sdr)"
if [ "$SDR_MODE" == "none" ]; then
  log "ISS pass skipped: no RTL-SDR found (the ISS records with rtl_fm)" "WARN"
  exit 0
fi
log "ISS records on RTL-SDR #${SDR_INDEX} ($([ "$SDR_MODE" == dedicated ] && echo "its own, alongside the Meteors" || echo "shared with the Meteors, which come first"))" "INFO"

if [ "$SDR_MODE" == "shared" ]; then
  # a Meteor pass that is still being decoded keeps the SDR busy: wait up to a minute, then give up
  for _ in $(seq 12); do pgrep -f "$METEOR_RUNNING" >/dev/null || break; sleep 5; done
  if pgrep -f "$METEOR_RUNNING" >/dev/null; then
    log "ISS pass skipped: a Meteor capture is still using the SDR" "WARN"
    exit 0
  fi

  # Meteor has priority: stop recording 20 s before the next scheduled Meteor pass starts
  now=$(date +%s)
  next_meteor=$($SQLITE3 "$DB_FILE" "SELECT MIN(pass_start) FROM predict_passes WHERE is_active = 1
                 AND sat_name LIKE 'METEOR%' AND pass_end > $now AND pass_start < $((now + CAPTURE_TIME + 20));" 2>/dev/null)
  if [ -n "$next_meteor" ]; then
    left=$(( next_meteor - now - 20 ))
    if [ "$left" -lt 60 ]; then
      log "ISS pass skipped: a Meteor pass starts at $(date -d "@$next_meteor" +%H:%M:%S)" "INFO"
      $SQLITE3 "$DB_FILE" "DELETE FROM predict_passes WHERE pass_start = $EPOCH_START AND sat_name = 'ISS';" >> "$LRPT_LOG" 2>&1
      exit 0
    fi
    [ "$left" -lt "$CAPTURE_TIME" ] && { log "ISS recording cut to ${left} s: a Meteor pass starts at $(date -d "@$next_meteor" +%H:%M:%S)" "INFO"; CAPTURE_TIME=$left; }
  fi
fi

WORK_DIR=$(work_dir "iss-${FILENAME_BASE}")
trap 'cd "$LRPT_HOME"; rm -rf "$WORK_DIR"; rm -f "$ISS_SDR_MARK"' EXIT
echo "$SDR_INDEX $SDR_MODE" > "$ISS_SDR_MARK"     # receive_meteor.sh stops a shared recording only
RAW="$WORK_DIR/pass.raw"

# rtl_fm options: the chosen dongle with the ISS gain; a shared dongle keeps the Meteors' ppm and
# bias tee, the ISS's own one uses iss_bias_tee
dev_args="-d $SDR_INDEX"
ppm_args=""
bias_args=""
if [ "$SDR_MODE" == "shared" ]; then
  [ -n "$METEOR_M2_3_FREQ_OFFSET" ] && [ "$METEOR_M2_3_FREQ_OFFSET" != "0" ] && ppm_args="-p $METEOR_M2_3_FREQ_OFFSET"
  [ "$METEOR_M2_3_ENABLE_BIAS_TEE" == "-T" ] && bias_args="-T"
else
  [ "$ISS_BIAS_TEE" == "true" ] && bias_args="-T"
fi

# The ISS on its own RTL-SDR (two dongles) records the whole band the dongle sees (2.38 MS/s)
# with rtl_sdr: iq_fm.py demodulates the ISS frequency on the way (audio at 22 050 Hz) and keeps
# a spectrum a second for the pass's spectrogram, drawn every pass, heard or not. A dongle shared
# with the Meteors keeps the plain rtl_fm recording.
WIDE=false
SPEC_NPZ="$WORK_DIR/iss-spectrum.npz"
if [ "$SDR_MODE" == "dedicated" ] && command -v rtl_sdr >/dev/null && python3 -c 'import scipy' 2>/dev/null; then
  WIDE=true
  RATE=22050
fi
# the Passes page's live ISS panel (PassesController::issliveAction, assets/js/iss_live.js):
# iss-live-info.json (mode, times, frequencies, the expected Doppler every 5 s) from here,
# iss-live.json (the spectra, once a second) from iq_fm.py; both go when the script ends
ISS_LIVE="${IMAGE_OUTPUT}/iss-live.json"
ISS_LIVE_INFO="${IMAGE_OUTPUT}/iss-live-info.json"
iss_live_info() {     # MODE MHZ
  [ "$WIDE" == "true" ] || return 0
  python3 - "$1" "$2" "$TLE_FILE" "$SAT_NAME" "$LAT" "$LON" "$(date +%s)" "$CAPTURE_TIME" "$SAT_MAX_ELEVATION" \
      "$ISS_LIVE_INFO" "$IMAGE_PROC_DIR" <<'PY' 2>> "$LRPT_LOG"
import json, os, sys
mode, mhz, tle, sat, lat, lon, start, cap, maxel, out, proc = sys.argv[1:]
sys.path.insert(0, proc)
import spectrogram
start, cap, target = int(start), int(cap), float(mhz) * 1e6
times = list(range(start, start + cap + 1, 5))
dop = spectrogram.doppler(tle, sat, lat, lon, times, target)
info = {'mode': mode, 'start': start, 'end': start + cap, 'frequency': float(mhz), 'max_elev': maxel,
        'center_hz': target - 264600, 'rate': 2381400, 'zoom_span': 44100,
        'doppler': [[t, round(float(d))] for t, d in zip(times, dop)] if dop is not None else []}
json.dump(info, open(out + '.tmp', 'w'))
os.replace(out + '.tmp', out)
PY
}
trap 'cd "$LRPT_HOME"; rm -rf "$WORK_DIR"; rm -f "$ISS_SDR_MARK" "$ISS_LIVE" "$ISS_LIVE_INFO"' EXIT

# iss_audio MHZ RATE: FM audio of the pass on stdout (signed 16-bit mono)
iss_audio() {
  local mhz=$1 rate=$2
  if [ "$WIDE" == "true" ]; then
    local target center
    target=$(awk -v f="$mhz" 'BEGIN { printf "%.0f", f * 1e6 }')
    center=$((target - 264600))                          # the ISS frequency 264.6 kHz above centre
    timeout $((CAPTURE_TIME + 10)) rtl_sdr -s 2381400 -f "$center" -g "$ISS_SSTV_GAIN" \
      -n $((2381400 * CAPTURE_TIME)) $dev_args $ppm_args $bias_args - 2>> "$LRPT_LOG" |
      python3 "$IMAGE_PROC_DIR/iq_fm.py" "$SPEC_NPZ" "$center" "$target" "$ISS_LIVE" 2>> "$LRPT_LOG"
  else
    timeout "$CAPTURE_TIME" $RTL_FM -f "${mhz}M" -M fm -s 48000 -r "$rate" -g "$ISS_SSTV_GAIN" -E dc \
      $dev_args $ppm_args $bias_args - 2>> "$LRPT_LOG"
  fi
}
# iss_spectrogram MODE: draw the pass's spectrogram (wide recording only); sets has_spectrogram
has_spectrogram=0
iss_spectrogram() {
  [ -s "$SPEC_NPZ" ] || return 1
  python3 "$IMAGE_PROC_DIR/spectrogram.py" render-iq "$SPEC_NPZ" "${IMAGE_FILE_BASE}-spectrogram.png" \
    "$SAT_NAME" "$TLE_FILE" "$LAT" "$LON" "$ISS_SSTV_MIN_ELEV" "$1" >> "$LRPT_LOG" 2>&1 || return 1
  "$IMAGE_PROC_DIR/thumbnail.sh" 300 "${IMAGE_FILE_BASE}-spectrogram.png" "${IMAGE_THUMB_BASE}-spectrogram.png" >> "$LRPT_LOG" 2>&1
  has_spectrogram=1
  log "Spectrogram of the whole band saved" "INFO"
}

# SSTV during an event, APRS the rest of the time (iss_aprs)
mode=sstv
if [ "${ISS_APRS}" == "true" ]; then
  read -r ev_from ev_to <<< "${ISS_SSTV_DATES}"
  pass_day=$(date -d "@$EPOCH_START" +%F)
  if [ -z "$ev_from" ] || [[ "$pass_day" < "$ev_from" || "$pass_day" > "$ev_to" ]]; then mode=aprs; fi
fi
if [ "$mode" == "aprs" ]; then
  LIVE_JSON="${IMAGE_OUTPUT}/aprs-live.json"
  LIVE_CSV="${IMAGE_OUTPUT}/aprs-live.csv"
  trap 'pkill -f "tail -n [+]1 -F --pid=$$ $LIVE_CSV" 2>/dev/null; cd "$LRPT_HOME"; rm -rf "$WORK_DIR"; rm -f "$LIVE_JSON" "$LIVE_CSV" "$ISS_SDR_MARK" "$ISS_LIVE" "$ISS_LIVE_INFO"' EXIT
  ARATE=22050
  printf 'ADEVICE stdin null\nCHANNEL 0\nMODEM 1200\n' > "$WORK_DIR/direwolf.conf"
  rm -f "$LIVE_CSV"
  printf '{"base":"%s","start":%s,"end":%s,"frequency":%s}\n' "$FILENAME_BASE" "$(date +%s)" \
    "$(( $(date +%s) + CAPTURE_TIME ))" "$ISS_APRS_FREQ" > "$LIVE_JSON"
  log "Recording ISS APRS ${ISS_APRS_FREQ} MHz for ${CAPTURE_TIME} s (max elevation ${SAT_MAX_ELEVATION}°), decoding live" "INFO"
  # one log line per packet as Dire Wolf decodes it (the Live log follows the pass too)
  # --pid: tail (and with it the whole follower) ends when this script does, whatever happens
  ( tail -n +1 -F --pid=$$ "$LIVE_CSV" 2>/dev/null | python3 -u "$IMAGE_PROC_DIR/aprs_pass.py" --follow 2>/dev/null |
      while IFS= read -r heard; do log "APRS heard $heard" "INFO"; done ) &
  iss_live_info APRS "$ISS_APRS_FREQ"
  iss_audio "$ISS_APRS_FREQ" $ARATE | tee "$RAW" | \
    direwolf -c "$WORK_DIR/direwolf.conf" -r $ARATE -b 16 -n 1 -t 0 -a 0 -q hd -L "$LIVE_CSV" - \
    > "$WORK_DIR/direwolf.out" 2>&1
  sleep 1                                   # let the last packet reach the log
  # [+]: a bare + is a pattern character for pkill, so "tail -n +1" never matched (v1.37.3)
  pkill -f "tail -n [+]1 -F --pid=$$ $LIVE_CSV" 2>/dev/null
  rm -f "$LIVE_JSON"

  stations=$(python3 "$IMAGE_PROC_DIR/aprs_pass.py" "$LIVE_CSV" "$WORK_DIR/direwolf.out" "$TLE_FILE" "$SAT_NAME" \
             "$EPOCH_START" $((EPOCH_START + CAPTURE_TIME)) "$LAT" "$LON" "$IMAGE_FILE_BASE" "$ISS_APRS_FREQ" 2>> "$LRPT_LOG" | tail -1)
  packets=$(grep -c '^\[' "$WORK_DIR/direwolf.out" 2>/dev/null)
  iss_spectrogram "APRS"
  if [ "${stations:-0}" -eq 0 ] 2>/dev/null || [ -z "$stations" ]; then
    stations=0
    log "No APRS packets heard in this ISS pass" "INFO"
    if [ "$has_spectrogram" -eq 0 ]; then
      $SQLITE3 "$DB_FILE" "DELETE FROM predict_passes WHERE pass_start = $EPOCH_START AND sat_name = 'ISS';" >> "$LRPT_LOG" 2>&1
      exit 0
    fi
    # the pass stays on the site with its spectrogram
    "$IMAGE_PROC_DIR/thumbnail.sh" 300 "${IMAGE_FILE_BASE}-spectrogram.png" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg" >> "$LRPT_LOG" 2>&1
  else
    log "APRS: ${stations} station(s), ${packets:-?} packet(s) heard through the ISS" "INFO"
    "$IMAGE_PROC_DIR/thumbnail.sh" 300 "${IMAGE_FILE_BASE}-aprs-map.png" "${IMAGE_THUMB_BASE}-aprs-map.png" >> "$LRPT_LOG" 2>&1
    "$IMAGE_PROC_DIR/thumbnail.sh" 300 "${IMAGE_FILE_BASE}-aprs-map.png" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg" >> "$LRPT_LOG" 2>&1
  fi

  if [ "${KEEP_RECORDINGS:-0}" -gt 0 ]; then
    $SOX -t raw -r $ARATE -e signed -b 16 -c 1 "$RAW" "${AUDIO_FILE_BASE}.wav" >> "$LRPT_LOG" 2>&1 &&
      log "Recording kept as ${AUDIO_FILE_BASE}.wav ($(du -h "${AUDIO_FILE_BASE}.wav" | cut -f1))" "INFO"
    ls -1t "${METEOR_AUDIO_OUTPUT}"/ISS-*.wav 2>/dev/null | tail -n +$((KEEP_RECORDINGS + 1)) | xargs -r rm -f
  fi

  daylight=0
  [ "$(python3 "$SCRIPTS_DIR/tools/sun.py" $((EPOCH_START + CAPTURE_TIME / 2)))" -gt "${METEOR_M2_3_SUN_MIN_ELEV:-0}" ] && daylight=1
  # sat_type 4 = ISS APRS; img_count = stations heard
  $SQLITE3 "$DB_FILE" "INSERT OR REPLACE INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, img_count, has_spectrogram, has_polar_az_el, has_polar_direction, gain) \
                       VALUES ($EPOCH_START, \"$FILENAME_BASE\", $daylight, 4, $stations, $has_spectrogram, 0, 0, $ISS_SSTV_GAIN);" >> "$LRPT_LOG" 2>&1
  pass_id=$($SQLITE3 "$DB_FILE" "SELECT id FROM decoded_passes WHERE pass_start = $EPOCH_START;")
  $SQLITE3 "$DB_FILE" "UPDATE predict_passes SET is_active = 0 WHERE pass_start = $EPOCH_START;" >> "$LRPT_LOG" 2>&1
  log "ISS APRS pass added to the site (${stations} station(s))" "INFO"
  [ "$stations" -gt 0 ] && { discord_pass "$FILENAME_BASE" "$daylight" "ISS-APRS" "$EPOCH_START" "$SAT_MAX_ELEVATION" \
               "$PASS_DIRECTION" "$CAPTURE_TIME" "$pass_id" || true; }
  log "Total processing time: $(date -ud "@$(( $(date +%s) - TIMER_START ))" +'%H:%M.%S')" "INFO"
  exit 0
fi

log "Recording ISS ${ISS_FREQ} MHz FM for ${CAPTURE_TIME} s (max elevation ${SAT_MAX_ELEVATION}°)" "INFO"
# 48 kHz: room for the FM signal plus the Doppler shift (±3.5 kHz on 2 m, ±10 kHz on 70 cm); audio 11025 Hz
iss_live_info SSTV "$ISS_FREQ"
iss_audio "$ISS_FREQ" $RATE > "$RAW"
size=$(stat -c %s "$RAW" 2>/dev/null || echo 0)
log "Recorded $((size / 2 / RATE)) s of audio" "INFO"

log "Decoding SSTV" "INFO"
decoded=$(python3 "$IMAGE_PROC_DIR/sstv_decode.py" "$RAW" "$WORK_DIR/sstv" --rate $RATE 2>> "$LRPT_LOG")
n=0
while read -r line; do
  [ -n "$line" ] || continue
  png=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["file"])' "$line")
  info=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["mode"], d["rows"], "rows", "complete" if d["complete"] else "partial")' "$line")
  n=$((n + 1))
  $CONVERT "$png" -quality 95 "${IMAGE_FILE_BASE}-SSTV_${n}.jpg" >> "$LRPT_LOG" 2>&1
  "$IMAGE_PROC_DIR/thumbnail.sh" 300 "${IMAGE_FILE_BASE}-SSTV_${n}.jpg" "${IMAGE_THUMB_BASE}-SSTV_${n}.jpg" >> "$LRPT_LOG" 2>&1
  log "SSTV picture ${n}: ${info}" "INFO"
done <<< "$decoded"

iss_spectrogram "SSTV"
if [ "$n" -eq 0 ]; then
  log "No SSTV pictures in this ISS pass (no ARISS event, or too weak)" "INFO"
  if [ "$has_spectrogram" -eq 0 ]; then
    $SQLITE3 "$DB_FILE" "DELETE FROM predict_passes WHERE pass_start = $EPOCH_START AND sat_name = 'ISS';" >> "$LRPT_LOG" 2>&1
    exit 0
  fi
  # the pass stays on the site with its spectrogram
  "$IMAGE_PROC_DIR/thumbnail.sh" 300 "${IMAGE_FILE_BASE}-spectrogram.png" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg" >> "$LRPT_LOG" 2>&1
else
  cp "${IMAGE_THUMB_BASE}-SSTV_1.jpg" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg"
fi

# the recording, for decoding again later (the same keep_recordings count as the Meteor frames)
if [ "${KEEP_RECORDINGS:-0}" -gt 0 ]; then
  $SOX -t raw -r $RATE -e signed -b 16 -c 1 "$RAW" "${AUDIO_FILE_BASE}.wav" >> "$LRPT_LOG" 2>&1 &&
    log "Recording kept as ${AUDIO_FILE_BASE}.wav ($(du -h "${AUDIO_FILE_BASE}.wav" | cut -f1))" "INFO"
  ls -1t "${METEOR_AUDIO_OUTPUT}"/ISS-*.wav 2>/dev/null | tail -n +$((KEEP_RECORDINGS + 1)) | xargs -r rm -f
fi

polar_direction=0
if [[ "${PRODUCE_POLAR_DIRECTION}" == "true" ]]; then
  python3 "$IMAGE_PROC_DIR/polar_plot.py" "$SAT_NAME" "$TLE_FILE" "$EPOCH_START" $((EPOCH_START + CAPTURE_TIME)) \
    "$LAT" "$LON" "$ISS_SSTV_MIN_ELEV" "$PASS_DIRECTION" "${IMAGE_FILE_BASE}-polar-direction.png" direction >> "$LRPT_LOG" 2>&1 &&
    "$IMAGE_PROC_DIR/thumbnail.sh" 300 "${IMAGE_FILE_BASE}-polar-direction.png" "${IMAGE_THUMB_BASE}-polar-direction.png" >> "$LRPT_LOG" 2>&1 &&
    polar_direction=1
fi

daylight=0
[ "$(python3 "$SCRIPTS_DIR/tools/sun.py" $((EPOCH_START + CAPTURE_TIME / 2)))" -gt "${METEOR_M2_3_SUN_MIN_ELEV:-0}" ] && daylight=1

# sat_type 3 = ISS SSTV (0 = Meteor)
$SQLITE3 "$DB_FILE" "INSERT OR REPLACE INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, img_count, has_spectrogram, has_polar_az_el, has_polar_direction, gain) \
                     VALUES ($EPOCH_START, \"$FILENAME_BASE\", $daylight, 3, $n, $has_spectrogram, 0, $polar_direction, $ISS_SSTV_GAIN);" >> "$LRPT_LOG" 2>&1
pass_id=$($SQLITE3 "$DB_FILE" "SELECT id FROM decoded_passes WHERE pass_start = $EPOCH_START;")
$SQLITE3 "$DB_FILE" "UPDATE predict_passes SET is_active = 0 WHERE pass_start = $EPOCH_START;" >> "$LRPT_LOG" 2>&1
log "ISS pass added to the site with ${n} SSTV picture(s)$([ "$has_spectrogram" -eq 1 ] && echo " and its spectrogram")" "INFO"

[ "$n" -gt 0 ] && { discord_pass "$FILENAME_BASE" "$daylight" "$SAT_NAME" "$EPOCH_START" "$SAT_MAX_ELEVATION" \
             "$PASS_DIRECTION" "$CAPTURE_TIME" "$pass_id" || true; }

log "Total processing time: $(date -ud "@$(( $(date +%s) - TIMER_START ))" +'%H:%M.%S')" "INFO"
