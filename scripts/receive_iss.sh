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

if [ "$RECEIVER_TYPE" != "rtlsdr" ]; then
  log "ISS SSTV needs an RTL-SDR (rtl_fm); receiver is ${RECEIVER_TYPE} - skipped" "WARN"
  exit 0
fi
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

WORK_DIR=$(work_dir "iss-${FILENAME_BASE}")
trap 'cd "$LRPT_HOME"; rm -rf "$WORK_DIR"' EXIT
RAW="$WORK_DIR/pass.raw"

# rtl_fm options: the station's RTL-SDR settings (device, ppm, bias tee) with the ISS gain
dev_args=""
[ "$USE_DEVICE_STRING" == "true" ] && [ -n "$METEOR_M2_3_SDR_DEVICE_ID" ] && dev_args="-d $METEOR_M2_3_SDR_DEVICE_ID"
ppm_args=""
[ -n "$METEOR_M2_3_FREQ_OFFSET" ] && [ "$METEOR_M2_3_FREQ_OFFSET" != "0" ] && ppm_args="-p $METEOR_M2_3_FREQ_OFFSET"
bias_args=""
[ "$METEOR_M2_3_ENABLE_BIAS_TEE" == "-T" ] && bias_args="-T"

log "Recording ISS ${ISS_FREQ} MHz FM for ${CAPTURE_TIME} s (max elevation ${SAT_MAX_ELEVATION}°)" "INFO"
# 48 kHz: room for the FM signal plus the Doppler shift (±3.5 kHz on 2 m, ±10 kHz on 70 cm); audio 11025 Hz
timeout "$CAPTURE_TIME" $RTL_FM -f "${ISS_FREQ}M" -M fm -s 48000 -r $RATE -g "$ISS_SSTV_GAIN" -E dc \
  $dev_args $ppm_args $bias_args - > "$RAW" 2>> "$LRPT_LOG"
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

if [ "$n" -eq 0 ]; then
  log "No SSTV pictures in this ISS pass (no ARISS event, or too weak)" "INFO"
  $SQLITE3 "$DB_FILE" "DELETE FROM predict_passes WHERE pass_start = $EPOCH_START AND sat_name = 'ISS';" >> "$LRPT_LOG" 2>&1
  exit 0
fi

cp "${IMAGE_THUMB_BASE}-SSTV_1.jpg" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg"

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
                     VALUES ($EPOCH_START, \"$FILENAME_BASE\", $daylight, 3, $n, 0, 0, $polar_direction, $ISS_SSTV_GAIN);" >> "$LRPT_LOG" 2>&1
pass_id=$($SQLITE3 "$DB_FILE" "SELECT id FROM decoded_passes WHERE pass_start = $EPOCH_START;")
$SQLITE3 "$DB_FILE" "UPDATE predict_passes SET is_active = 0 WHERE pass_start = $EPOCH_START;" >> "$LRPT_LOG" 2>&1
log "ISS pass added to the site with ${n} SSTV picture(s)" "INFO"

discord_pass "$FILENAME_BASE" "$daylight" "$SAT_NAME" "$EPOCH_START" "$SAT_MAX_ELEVATION" \
             "$PASS_DIRECTION" "$CAPTURE_TIME" "$pass_id" || true

log "Total processing time: $(date -ud "@$(( $(date +%s) - TIMER_START ))" +'%H:%M.%S')" "INFO"
