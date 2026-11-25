#!/bin/bash
#
# Purpose: Receive and process Meteor-M 2 captures.
#
# Input parameters:
#   1. Name of satellite "METEOR-M 2"
#   2. Filename of image outputs
#   3. TLE file location
#   4. Duration of capture (seconds)
#   5. Max angle elevation for satellite
#   6. Direction of pass
#   7. Side of pass (W=West, E=East) relative to base station
#
# Example:
#   ./receive_meteor.sh "METEOR-M 2" METEOR-M220210205-192623 1612571183 922 39 Northbound W

# time keeping
TIMER_START=$(date '+%s')

# import common lib and settings
. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

# input params
export SAT_NAME=$1
export FILENAME_BASE=$2
export TLE_FILE=$3
export EPOCH_START=$4
export CAPTURE_TIME=$5
export SAT_MAX_ELEVATION=$6
export PASS_DIRECTION=$7
export PASS_SIDE=$8
# the annotation's pass time (an at job inherits the scheduler's START_DATE otherwise)
export START_DATE; START_DATE=$(date -d "@$EPOCH_START" '+%d-%m-%Y %H:%M')

# base directory plus filename_base for re-use
AUDIO_FILE_BASE="${METEOR_AUDIO_OUTPUT}/${FILENAME_BASE}"
IMAGE_FILE_BASE="${IMAGE_OUTPUT}/${FILENAME_BASE}"
IMAGE_THUMB_BASE="${IMAGE_OUTPUT}/thumb/${FILENAME_BASE}"

case "$RECEIVER_TYPE" in
     "rtlsdr")
         samplerate="1.024e6"
         receiver="rtlsdr"
         ;;
     "airspy_mini")
         samplerate="3e6"
         receiver="airspy"
         ;;
     "airspy_r2")
         samplerate="2.5e6"
         receiver="airspy"
         ;;
     "airspy_hf_plus_discovery")
         samplerate="192e3"
         receiver="airspyhf"
         ;;
     "hackrf")
         samplerate="2e6"
         receiver="hackrf"
         ;;
     "sdrplay")
         samplerate="2e6"
         receiver="sdrplay"
         ;;
     "mirisdr")
         samplerate="2e6"
         receiver="mirisdr"
         ;;
     *)
         log "Unsupported RECEIVER_TYPE: $RECEIVER_TYPE" "ERROR"
         exit 1
         ;;
esac

if [ "$SAT_NAME" == "METEOR-M2 3" ]; then
  SAT_NUMBER="M2_3"
  METEOR_FREQUENCY=$METEOR_M2_3_FREQ

  # export some variables for use in the annotation - note that we do not
  # want to export all of .raspberry-lrpt.conf because it contains sensitive info
  export GAIN=$METEOR_M2_3_GAIN
  export SUN_MIN_ELEV=$METEOR_M2_3_SUN_MIN_ELEV
  export SDR_DEVICE_ID=$METEOR_M2_3_SDR_DEVICE_ID
  export BIAS_TEE=$METEOR_M2_3_ENABLE_BIAS_TEE
  export FREQ_OFFSET=$METEOR_M2_3_FREQ_OFFSET
  export SAT_MIN_ELEV=$METEOR_M2_3_SAT_MIN_ELEV
elif [ "$SAT_NAME" == "METEOR-M2 4" ]; then
  SAT_NUMBER="M2_4"
  METEOR_FREQUENCY=$METEOR_M2_4_FREQ

  # export some variables for use in the annotation - note that we do not
  # want to export all of .raspberry-lrpt.conf because it contains sensitive info
  export GAIN=$METEOR_M2_4_GAIN
  export SUN_MIN_ELEV=$METEOR_M2_4_SUN_MIN_ELEV
  export SDR_DEVICE_ID=$METEOR_M2_4_SDR_DEVICE_ID
  export BIAS_TEE=$METEOR_M2_4_ENABLE_BIAS_TEE
  export FREQ_OFFSET=$METEOR_M2_4_FREQ_OFFSET
  export SAT_MIN_ELEV=$METEOR_M2_4_SAT_MIN_ELEV
fi

interleaving="METEOR_${SAT_NUMBER}_80K_INTERLEAVING"
mode="$([[ "${!interleaving}" == "true" ]] && echo "_80k" || echo "")"

# the gain setting (dB) in each receiver's own SatDump options
ppm_correction=""
case "$receiver" in
  rtlsdr)                    # 0-49.6 dB
    gain_args="--gain $GAIN"
    ppm_correction="--ppm_correction" ;;
  airspy)                    # 0-21 (linearity gain steps)
    gain_args="--general_gain $GAIN" ;;
  airspyhf)                  # automatic gain, no setting
    gain_args="" ;;
  hackrf)                    # 0-102 dB: LNA 0-40 in 8 dB steps first, the rest on the VGA (0-62, 2 dB steps)
    read -r lna vga < <(awk -v g="$GAIN" 'BEGIN { l = int(g / 8) * 8; if (l > 40) l = 40; if (l < 0) l = 0;
                                                v = int((g - l) / 2) * 2; if (v > 62) v = 62; if (v < 0) v = 0; print l, v }')
    gain_args="--lna_gain $lna --vga_gain $vga" ;;
  sdrplay)                   # IF gain 20-59; LNA state from sdr_extra_options, else 5
    gain_args="--if_gain $(awk -v g="$GAIN" 'BEGIN { g = int(g + 0.5); if (g < 20) g = 20; if (g > 59) g = 59; print g }')"
    [[ "$SDR_EXTRA_OPTIONS" == *"--lna_gain"* ]] || gain_args="$gain_args --lna_gain 5" ;;
  mirisdr)                   # 0-100 dB, set in 10 dB steps
    gain_args="--gain $(awk -v g="$GAIN" 'BEGIN { g = int(g / 10 + 0.5); if (g < 0) g = 0; if (g > 10) g = 10; print g }')" ;;
esac
[ "$receiver" == "rtlsdr" ] || FREQ_OFFSET=""

if [[ "$USE_DEVICE_STRING" == "true" ]]; then
  sdr_id_option="--source_id"
  if [ "$receiver" == "rtlsdr" ]; then
    # SatDump matches --source_id to the serial exactly: turn "1" (or an index, or part of the
    # model name) into the connected dongle's serial, e.g. 00000001
    real_serial=$(python3 "$SCRIPTS_DIR/tools/rtlsdr_list.py" serial "$SDR_DEVICE_ID" 2>/dev/null)
    if [ -n "$real_serial" ] && [ "$real_serial" != "$SDR_DEVICE_ID" ]; then
      log "RTL-SDR '$SDR_DEVICE_ID' is serial $real_serial" "INFO"
      SDR_DEVICE_ID=$real_serial
    elif [ -z "$real_serial" ]; then
      log "No connected RTL-SDR matches '$SDR_DEVICE_ID' (scripts/switch.sh iss lists them)" "WARN"
    fi
  fi
else
  sdr_id_option=""
  SDR_DEVICE_ID=""
fi

if [ "$BIAS_TEE" == "-T" ]; then
    bias_tee_option="--bias"
else
    bias_tee_option=""
fi

finish_processing="--finish_processing"

FLIP=""
log "Direction $PASS_DIRECTION" "INFO"
if [ "$PASS_DIRECTION" == "Northbound" ] && [ "$FLIP_METEOR_IMG" == "true" ]; then
  log "I'll flip this image pass because FLIP_METEOR_IMG is set to true and PASS_DIRECTION is Northbound" "INFO"
  FLIP="-rotate 180"
fi

# pass start timestamp and sun elevation
PASS_START=$(expr "$EPOCH_START" + 90)
export SUN_ELEV=$(python3 "$SCRIPTS_DIR"/tools/sun.py "$PASS_START")

# determine if pass is in daylight
daylight=0
if [ "${SUN_ELEV}" -gt "${SUN_MIN_ELEV}" ]; then daylight=1; fi

# TODO: Fix this up - this conditional selection is a massive bit of complexity that
#       needs to be handled, but in the interest of not breaking everything (at least in
#       the first round), keeping it simple.
spectrogram=0
polar_az_el=0
polar_direction=0

#---------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Meteor has priority over the ISS (iss_sstv): an ISS recording on the Meteors' own RTL-SDR is
# stopped (its pictures so far are still decoded by receive_iss.sh); one on its own dongle
# (iss_sdr_device, a second RTL-SDR) keeps recording
band_scan_yield meteor     # a band scan (Admin > Band scan) on the Meteors' dongle stops
if pgrep -f "$ISS_RUNNING" >/dev/null 2>&1 && ! grep -q ' dedicated$' "$ISS_SDR_MARK" 2>/dev/null; then
  log "Stopping the ISS recording: the Meteor pass has priority" "WARN"
  pkill -f "rtl_fm -f (${ISS_FREQ}|${ISS_APRS_FREQ})M" 2>/dev/null
  for _ in 1 2 3 4 5 6; do pgrep -f "rtl_fm -f (${ISS_FREQ}|${ISS_APRS_FREQ})M" >/dev/null || break; sleep 0.5; done
  sleep 1                                  # let the USB device go
fi

log "Recording ${SAT_NAME} via $receiver at ${METEOR_FREQUENCY} MHz with satdump live" "INFO"
# SatDump's working folder: it writes the frames and ~250 MB of images there while decoding.
# With storage: sd it is on the RAM disk (when that has room), which spares the SD card.
WORK_DIR=$(work_dir "pass-${FILENAME_BASE}")
case "$WORK_DIR" in
  "$RAMFS_AUDIO"/*) log "Working folder on the RAM disk: $WORK_DIR" "INFO" ;;
  *)                log "Working folder on disk: $WORK_DIR" "INFO" ;;
esac
cd "$WORK_DIR" || { log "Can't use the working folder $WORK_DIR" "ERROR"; exit 1; }
# whatever happens, the folder doesn't stay behind (on the RAM disk it would hold memory)
LIVE_FILE="${IMAGE_OUTPUT}/live.json"
PREVIEW_FILES="${IMAGE_OUTPUT}/live-preview.jpg ${IMAGE_OUTPUT}/live-preview.json"
preview_pid=""
trap 'cd "$LRPT_HOME"; [ -n "$preview_pid" ] && kill "$preview_pid" 2>/dev/null; rm -rf "$WORK_DIR"; rm -f "$LIVE_FILE" $PREVIEW_FILES' EXIT
audio_temporary_storage_directory="$WORK_DIR"
# spectrogram: SatDump has no recording to analyse afterwards, so its built-in web server
# serves the live spectrum and spectrogram.py samples it once a second during the pass
# The same server feeds the web panel's live signal view (PassesController::liveAction), which
# finds the pass in $IMAGE_OUTPUT/live.json while SatDump runs.
SPECTRO_PORT=8091
spectro_opts="--fft_enable --fft_size 4096 --fft_rate 4 --http_server 127.0.0.1:${SPECTRO_PORT}"
spectro_pid=""
SPECTRO_DATA="${LRPT_HOME}/tmp/spectrogram-${FILENAME_BASE}.npz"
printf '{"sat":"%s","start":%s,"end":%s,"samplerate":%s,"frequency":%s,"max_elev":%s,"port":%s}\n' \
  "$SAT_NAME" "$(date +%s)" "$(( $(date +%s) + CAPTURE_TIME ))" "$(awk -v s="$samplerate" 'BEGIN { printf "%d", s }')" \
  "${METEOR_FREQUENCY}" "${SAT_MAX_ELEVATION:-0}" "$SPECTRO_PORT" > "$LIVE_FILE" 2>/dev/null
chmod 644 "$LIVE_FILE" 2>/dev/null
# live preview (live_preview): a small picture of the frames decoded so far, for the live panel
rm -f $PREVIEW_FILES
if [[ "${LIVE_PREVIEW}" == "true" ]]; then
  flip=false
  [ "$PASS_DIRECTION" == "Northbound" ] && [ "$FLIP_METEOR_IMG" == "true" ] && flip=true
  "$LRPT_HOME/scripts/live_preview.sh" "$WORK_DIR/meteor_m2-x_lrpt${mode}.cadu" \
    "$(sed -n 's/.*"start":\([0-9]*\).*/\1/p' "$LIVE_FILE")" "$daylight" "$flip" >> $LRPT_LOG 2>&1 &
  preview_pid=$!
fi
if [[ "${PRODUCE_SPECTROGRAM}" == "true" ]]; then
  python3 "${IMAGE_PROC_DIR}/spectrogram.py" record "${SPECTRO_PORT}" "${samplerate}" "${CAPTURE_TIME}" "${SPECTRO_DATA}" "${METEOR_FREQUENCY}" >> $LRPT_LOG 2>&1 &
  spectro_pid=$!
fi

log "$SATDUMP live meteor_m2-x_lrpt${mode} $audio_temporary_storage_directory --source $receiver --samplerate $samplerate $ppm_correction ${FREQ_OFFSET} --frequency ${METEOR_FREQUENCY}e6 $sdr_id_option $SDR_DEVICE_ID $gain_args $bias_tee_option $SDR_EXTRA_OPTIONS $finish_processing --fill_missing --timeout $CAPTURE_TIME $spectro_opts" "INFO"
satdump_started=$(date +%s)
$SATDUMP live meteor_m2-x_lrpt${mode} "$audio_temporary_storage_directory" --source $receiver --samplerate $samplerate $ppm_correction ${FREQ_OFFSET} --frequency "${METEOR_FREQUENCY}e6" $sdr_id_option $SDR_DEVICE_ID $gain_args $bias_tee_option $SDR_EXTRA_OPTIONS $finish_processing --fill_missing --timeout $CAPTURE_TIME $spectro_opts >> $LRPT_LOG 2>&1
satdump_ran=$(( $(date +%s) - satdump_started ))
rm -f "$LIVE_FILE"
[ -n "$preview_pid" ] && { kill "$preview_pid" 2>/dev/null; wait "$preview_pid" 2>/dev/null; preview_pid=""; }
[ -n "$spectro_pid" ] && wait "$spectro_pid"

# draw the spectrogram straight away, so it exists even when nothing could be decoded
# (it then shows why: no signal, or a signal the decoder never locked on to)
if [[ "${PRODUCE_SPECTROGRAM}" == "true" ]] && [ -f "${SPECTRO_DATA}" ]; then
  log "Producing spectrogram" "INFO"
  if python3 "${IMAGE_PROC_DIR}/spectrogram.py" render "${SPECTRO_DATA}" "${IMAGE_FILE_BASE}-spectrogram.png" \
       "${SAT_NAME}" "${TLE_FILE}" "${LAT}" "${LON}" "${SAT_MIN_ELEV}" >> $LRPT_LOG 2>&1; then
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-spectrogram.png" "${IMAGE_THUMB_BASE}-spectrogram.png" >> $LRPT_LOG 2>&1
    spectro_thumbs "${IMAGE_FILE_BASE}" "${IMAGE_THUMB_BASE}"
    log "Spectrogram saved to ${IMAGE_FILE_BASE}-spectrogram.png" "INFO"
  else
    log "Spectrogram could not be drawn" "WARN"
  fi
fi
CADU_FILE="$WORK_DIR/meteor_m2-x_lrpt${mode}.cadu"
cadu_bytes=$(stat -c %s "$CADU_FILE" 2>/dev/null || echo 0)   # before the recording is moved away

# the pass's signal numbers (written by spectrogram.py render): quality, peak / mean SNR, lock time
q_quality=NULL; q_snr_peak=NULL; q_snr_avg=NULL; q_locked=NULL
SPECTRO_STATS="${SPECTRO_DATA%.npz}.json"
if [ -s "$SPECTRO_STATS" ]; then
  read -r q_quality q_snr_peak q_snr_avg q_locked < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = lambda k: "NULL" if d.get(k) is None else str(d[k])
print(v("quality"), v("snr_peak"), v("snr_avg"), v("locked_s"))' "$SPECTRO_STATS" 2>/dev/null || echo "NULL NULL NULL NULL")
  log "Signal: quality ${q_quality} %, peak SNR ${q_snr_peak} dB, decoder locked ${q_locked} s" "INFO"
fi

# keep the product (raw channels, line times, orbit) for the daily map, before it is deleted
save_daily_product . "$FILENAME_BASE" "$EPOCH_START"
# night passes: no images from the channels that need sunlight (before the raw channels go)
drop_dark_images "MSU-MR (Filled)"
# coldest cloud tops at night; the 3.7 um rain composite only at night
rain_images "MSU-MR (Filled)" "$daylight" "$([ -n "$FLIP" ] && echo true || echo false)"
# the pass on the station's area with the capitals in green
capitals_map "MSU-MR (Filled)" "$daylight" "$EPOCH_START"
find "MSU-MR (Filled)/" -type f ! -name "*projected*" ! -name "*corrected*" -delete

log "Deleting SatDump projected composites which have been generated, but the channels aren't broadcast" "INFO"
for projected_file in MSU-MR\ \(Filled\)/rgb_msu_mr_rgb_*_projected.png; do
    [ -e "$projected_file" ] || continue   # no such files: the pattern itself
    # Extract the corresponding corrected.png filename
    corrected_file="${projected_file/rgb_msu_mr_rgb_/msu_mr_rgb_}"
    corrected_file="${corrected_file/_projected.png/_corrected.png}"

    # Check if the corrected.png file does not exist
    if [ ! -e "$corrected_file" ]; then
        log "$corrected_file doesn't exist, hence deleting $projected_file" "INFO"
        rm "$projected_file"
    fi
done

if satdump_times_ok . "$EPOCH_START"; then
  log "Removing images without a map if they exist" "INFO"
  for file in MSU-MR\ \(Filled\)/*map.png; do
    [ -e "$file" ] && mv "$file" "${file/_map.png/.png}"
  done
else
  # the frames' times are nonsense (corrupt data), so any map would be in the wrong place
  log "SatDump's line times are hours away from the pass - keeping the images without a map" "WARN"
  rm -f MSU-MR\ \(Filled\)/*map.png MSU-MR\ \(Filled\)/*projected*.png MSU-MR\ \(Filled\)/*MCIR*.png
fi

# northbound passes come out upside down (south at the top); rotate them when
# flip_meteor_image is on. Southbound passes are left alone (no re-encoding).
if [ -n "$FLIP" ]; then
  log "Rotating the northbound pass's images 180 degrees" "INFO"
  for i in MSU-MR\ \(Filled\)/*_corrected.png; do
    $CONVERT "$i" $FLIP "$i" >> $LRPT_LOG 2>&1 &
    throttle
  done
  wait
fi

# Renaming files, annotating images and creating thumbnails, several images at once
log "Annotating images and creating thumbnails ($PARALLEL_JOBS at a time)" "INFO"
annotate_one() {
  local i=$1 path image_filename new_name
  path="$(pwd)"
  image_filename=$(basename "$i")
  new_name="$image_filename"

  # Use parameter expansion to remove the specified prefixes
  new_name="${new_name#msu_mr_rgb_}"
  new_name="${new_name#rgb_msu_mr_rgb_}"
  new_name="${new_name#rgb_msu_mr_rgb_}"
  new_name="${new_name#rgb_msu_mr_}"
  new_name="${new_name#msu_mr_}"

  # Rename the file with the new name
  mv "$i" "$path/MSU-MR (Filled)/$new_name" >> $LRPT_LOG 2>&1

  ${IMAGE_PROC_DIR}/meteor_normalize_annotate.sh "$path/MSU-MR (Filled)/$new_name" "${IMAGE_FILE_BASE}-${new_name%.png}.jpg" $METEOR_IMAGE_QUALITY >> $LRPT_LOG 2>&1
  ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-${new_name%.png}.jpg" "${IMAGE_THUMB_BASE}-${new_name%.png}.jpg" >> $LRPT_LOG 2>&1
  rm "$path/MSU-MR (Filled)/$new_name" >> $LRPT_LOG 2>&1
}
for i in MSU-MR\ \(Filled\)/*.png; do
  [ -e "$i" ] || continue
  annotate_one "$i" &
  throttle
done
wait
rm -r "MSU-MR (Filled)" >> $LRPT_LOG 2>&1
rm -r "MSU-MR" >> $LRPT_LOG 2>&1

# keep the decoded frames (.cadu) of the newest KEEP_RECORDINGS passes for offline
# re-processing in SatDump, e.g. satdump meteor_m2-x_lrpt cadu <file>.cadu <output_dir>
if [ "${KEEP_RECORDINGS:-0}" -gt 0 ] && [ -f "${CADU_FILE}" ]; then
  mv "${CADU_FILE}" "${AUDIO_FILE_BASE}.cadu" >> $LRPT_LOG 2>&1
  log "Recording kept as ${AUDIO_FILE_BASE}.cadu ($(du -h "${AUDIO_FILE_BASE}.cadu" | cut -f1))" "INFO"
  ls -1t "${METEOR_AUDIO_OUTPUT}"/*.cadu 2>/dev/null | tail -n +$((KEEP_RECORDINGS + 1)) | while read -r old; do
    log "Deleting old recording $(basename "$old")" "INFO"
    rm -f "$old"
  done
fi
# the working folder (frames not kept, dataset and telemetry files, anything left over)
cd "$LRPT_HOME" && rm -rf "$WORK_DIR"

#---------------------------------------------------------------------------------------------------------------------------------------------------------------------

if [ -n "$(find /srv/images -maxdepth 1 -type f -name "$(basename "$IMAGE_FILE_BASE")*.jpg" -print -quit)" ]; then

  meteor_suffixes=(
      '-MSA_corrected.jpg'
      '-MSA_projected.jpg'
      '-MCIR_corrected.jpg'
      '-MCIR_projected.jpg'
      '-321_corrected.jpg'
      '-321_projected.jpg'
      '-equidistant_321.jpg'
      '-equidistant_321_composite.jpg'
      '-mercator_321_composite.jpg'
      '-spread_321.jpg'
      '-spread_123.jpg'
      '-221_corrected.jpg'
      '-221_projected.jpg'
      '-equidistant_221.jpg'
      '-equidistant_221_composite.jpg'
      '-mercator_321_composite.jpg'
      '-spread_221.jpg'
      '-equidistant_654.jpg'
      '-equidistant_654.composite.jpg'
      '-mercator_654_composite.jpg'
      '-spread_654.jpg'
      '-Thermal_Channel_corrected.jpg'
      '-equidistant_67_composite.jpg'
      '-equidistant_68_composite.jpg'
      '-mercator_67_composite.jpg'
      '-mercator_68_composite.jpg'
      '-spread_67.jpg'
      '-spread_68.jpg'
  )

  # put the day or night thumbnail preference (settings.yml) ahead of the built-in list
  if [ "${daylight}" == "1" ]; then
    thumbnail_preference="${METEOR_DAY_THUMBNAIL}"
  else
    thumbnail_preference="${METEOR_NIGHT_THUMBNAIL}"
  fi
  preferred_suffixes=()
  for name in ${thumbnail_preference}; do
    preferred_suffixes+=("-${name}.jpg")
  done
  meteor_suffixes=("${preferred_suffixes[@]}" "${meteor_suffixes[@]}")
  log "Thumbnail preference for this pass (daylight=${daylight}): ${thumbnail_preference}" "INFO"

  # Iterate through the meteor_suffixes array
  for suffix in "${meteor_suffixes[@]}"; do
      if [[ -f "${IMAGE_THUMB_BASE}${suffix}" ]]; then
          cp "${IMAGE_THUMB_BASE}${suffix}" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg"
          break
      fi
  done
  # none of them made (e.g. a night pass without MCIR because the satellite's clock was off):
  # any corrected image, IR first, so the capture's card never shows a broken picture
  if [ ! -f "${IMAGE_THUMB_BASE}-website-thumbnail.jpg" ]; then
    fallback=$(ls "${IMAGE_THUMB_BASE}"-*IR*_corrected.jpg "${IMAGE_THUMB_BASE}"-*_corrected.jpg 2>/dev/null | head -1)
    [ -n "$fallback" ] && cp "$fallback" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg"
  fi

  log "Some images were produced, adding them to the database" "INFO"
  [ -f "${IMAGE_FILE_BASE}-spectrogram.png" ] && spectrogram=1
  if [[ "${PRODUCE_POLAR_AZ_EL}" == "true" ]]; then
    log "Producing polar graph of azimuth and elevation for pass" "INFO"
    polar_az_el=1
    epoch_end=$((EPOCH_START + CAPTURE_TIME))
    python3 ${IMAGE_PROC_DIR}/polar_plot.py "${SAT_NAME}" \
                                            "${TLE_FILE}" \
                                            $EPOCH_START \
                                            $epoch_end \
                                            $LAT \
                                            $LON \
                                            $SAT_MIN_ELEV \
                                            $PASS_DIRECTION \
                                            "${IMAGE_FILE_BASE}-polar-azel.jpg" \
                                            "azel"
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-polar-azel.jpg" "${IMAGE_THUMB_BASE}-polar-azel.jpg"
  fi

  polar_direction=0
  if [[ "${PRODUCE_POLAR_DIRECTION}" == "true" ]]; then
    log "Producing polar graph of direction for pass" "INFO"
    polar_direction=1
    epoch_end=$((EPOCH_START + CAPTURE_TIME))
    python3 ${IMAGE_PROC_DIR}/polar_plot.py "${SAT_NAME}" \
                                            "${TLE_FILE}" \
                                            $EPOCH_START \
                                            $epoch_end \
                                            $LAT \
                                            $LON \
                                            $SAT_MIN_ELEV \
                                            $PASS_DIRECTION \
                                            "${IMAGE_FILE_BASE}-polar-direction.png" \
                                            "direction"
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-polar-direction.png" "${IMAGE_THUMB_BASE}-polar-direction.png"
  fi

  # check if we got an image, and post-process if so

  log "I got a successful jpg images" "INFO"

  # insert or replace in case there was already an insert due to the spectrogram creation
  $SQLITE3 $DB_FILE "INSERT OR REPLACE INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, has_spectrogram, has_polar_az_el, has_polar_direction, gain, quality, snr_peak, snr_avg, locked_s) \
                                      VALUES ($EPOCH_START, \"$FILENAME_BASE\", $daylight, 0, $spectrogram, $polar_az_el, $polar_direction, $GAIN, $q_quality, $q_snr_peak, $q_snr_avg, $q_locked);" >> $LRPT_LOG 2>&1

  pass_id=$($SQLITE3 $DB_FILE "SELECT id FROM decoded_passes ORDER BY id DESC LIMIT 1;")
  $SQLITE3 $DB_FILE "UPDATE predict_passes \
                    SET is_active = 0 \
                    WHERE (predict_passes.pass_start) \
                    IN ( \
                      SELECT predict_passes.pass_start \
                      FROM predict_passes \
                      INNER JOIN decoded_passes \
                      ON predict_passes.pass_start = decoded_passes.pass_start \
                      WHERE decoded_passes.id = $pass_id \
                    );" >> $LRPT_LOG 2>&1

  # (the animation is redrawn by daily_map.sh, after the daily map)

  # add the pass to its day's daily map (in the background, at low priority)
  daily_map_later "$EPOCH_START"

  # post the pass to Discord (discord_webhook in settings; in the background, never waited for)
  discord_pass "$FILENAME_BASE" "$daylight" "$SAT_NAME" "$EPOCH_START" "$SAT_MAX_ELEVATION" \
               "$PASS_DIRECTION" "$CAPTURE_TIME" "$pass_id" || true
else
  # why: kept with the scheduled pass so the Passes page can say it (pass_fail_reason, common.sh)
  # no signal numbers and no frames from a full-length run: the SDR sent nothing at all
  recorded=""
  if [[ "${PRODUCE_SPECTROGRAM}" == "true" ]] && [ "$q_locked" = "NULL" ] && [ "${cadu_bytes:-0}" -eq 0 ] \
     && [ "${satdump_ran:-0}" -ge $((CAPTURE_TIME / 2)) ]; then
    recorded=none
    log "The SDR sent no samples during the pass (flat spectrum, no frames). Unplug and replug it, or reboot; check that no kernel DVB driver holds it (lsmod | grep rtl28)" "WARN"
  fi
  reason=$(pass_fail_reason "$q_snr_peak" "$q_locked" "$satdump_ran" "$CAPTURE_TIME" "$recorded")
  log "No images found ($reason: peak SNR ${q_snr_peak} dB, decoder locked ${q_locked} s, SatDump ran ${satdump_ran} s)" "INFO"
  $SQLITE3 $DB_FILE "UPDATE predict_passes SET fail_reason = '$reason', \
                       fail_detail = '${q_snr_peak}|${q_locked}|${satdump_ran}' \
                     WHERE pass_start = $EPOCH_START;" >> $LRPT_LOG 2>&1
fi

rm -f "${SPECTRO_DATA}" "${SPECTRO_STATS}"

# calculate and report total time for capture
TIMER_END=$(date '+%s')
DIFF=$(($TIMER_END - $TIMER_START))
PROC_TIME=$(date -ud "@$DIFF" +'%H:%M.%S')
log "Total processing time: ${PROC_TIME}" "INFO"
