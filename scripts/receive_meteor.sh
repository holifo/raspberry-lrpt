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
     *)
         log "Unsupported RECEIVER_TYPE: $RECEIVER_TYPE (RTL-SDR and Airspy only)" "ERROR"
         exit 1
         ;;
esac

if [ "$SAT_NAME" == "METEOR-M2 3" ]; then
  SAT_NUMBER="M2_3"
  SAT_NAME_METEORDEMOD="METEOR-M-2-3"
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
  SAT_NAME_METEORDEMOD="METEOR-M-2-4"
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

if [[ "$receiver" == "rtlsdr" ]]; then
  gain_option="--gain"
  ppm_correction="--ppm_correction"
else
  gain_option="--general_gain"
  FREQ_OFFSET=""
fi

if [[ "$USE_DEVICE_STRING" == "true" ]]; then
  sdr_id_option="--source_id"
else
  sdr_id_option=""
  SDR_DEVICE_ID=""
fi

if [ "$BIAS_TEE" == "-T" ]; then
    bias_tee_option="--bias"
else
    bias_tee_option=""
fi

if [ "$METEOR_DECODER" == "satdump" ]; then
  finish_processing="--finish_processing"
else
  finish_processing=""
fi

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

log "Recording ${LRPT_HOME} via $receiver at ${METEOR_FREQUENCY} MHz using SatDump record " "INFO"
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
trap 'cd "$LRPT_HOME"; rm -rf "$WORK_DIR"; rm -f "$LIVE_FILE"' EXIT
audio_temporary_storage_directory="$WORK_DIR"
# spectrogram: SatDump has no recording to analyse afterwards, so its built-in web server
# serves the live spectrum and spectrogram.py samples it once a second during the pass
# The same server feeds the web panel's live signal view (PassesController::liveAction), which
# finds the pass in $IMAGE_OUTPUT/live.json while SatDump runs.
SPECTRO_PORT=8091
spectro_opts="--fft_enable --fft_size 1024 --fft_rate 4 --http_server 127.0.0.1:${SPECTRO_PORT}"
spectro_pid=""
SPECTRO_DATA="${LRPT_HOME}/tmp/spectrogram-${FILENAME_BASE}.npz"
printf '{"sat":"%s","start":%s,"end":%s,"samplerate":%s,"frequency":%s,"max_elev":%s,"port":%s}\n' \
  "$SAT_NAME" "$(date +%s)" "$(( $(date +%s) + CAPTURE_TIME ))" "$(awk -v s="$samplerate" 'BEGIN { printf "%d", s }')" \
  "${METEOR_FREQUENCY}" "${SAT_MAX_ELEVATION:-0}" "$SPECTRO_PORT" > "$LIVE_FILE" 2>/dev/null
chmod 644 "$LIVE_FILE" 2>/dev/null
if [[ "${PRODUCE_SPECTROGRAM}" == "true" ]]; then
  python3 "${IMAGE_PROC_DIR}/spectrogram.py" record "${SPECTRO_PORT}" "${samplerate}" "${CAPTURE_TIME}" "${SPECTRO_DATA}" "${METEOR_FREQUENCY}" >> $LRPT_LOG 2>&1 &
  spectro_pid=$!
fi

log "$SATDUMP live meteor_m2-x_lrpt${mode} $audio_temporary_storage_directory --source $receiver --samplerate $samplerate $ppm_correction ${FREQ_OFFSET} --frequency ${METEOR_FREQUENCY}e6 $sdr_id_option $SDR_DEVICE_ID $gain_option $GAIN $bias_tee_option $finish_processing --fill_missing --timeout $CAPTURE_TIME $spectro_opts" "INFO"
$SATDUMP live meteor_m2-x_lrpt${mode} "$audio_temporary_storage_directory" --source $receiver --samplerate $samplerate $ppm_correction ${FREQ_OFFSET} --frequency "${METEOR_FREQUENCY}e6" $sdr_id_option $SDR_DEVICE_ID $gain_option $GAIN $bias_tee_option $finish_processing --fill_missing --timeout $CAPTURE_TIME $spectro_opts >> $LRPT_LOG 2>&1
rm -f "$LIVE_FILE"
[ -n "$spectro_pid" ] && wait "$spectro_pid"

# draw the spectrogram straight away, so it exists even when nothing could be decoded
# (it then shows why: no signal, or a signal the decoder never locked on to)
if [[ "${PRODUCE_SPECTROGRAM}" == "true" ]] && [ -f "${SPECTRO_DATA}" ]; then
  log "Producing spectrogram" "INFO"
  if python3 "${IMAGE_PROC_DIR}/spectrogram.py" render "${SPECTRO_DATA}" "${IMAGE_FILE_BASE}-spectrogram.png" \
       "${SAT_NAME}" "${TLE_FILE}" "${LAT}" "${LON}" "${SAT_MIN_ELEV}" >> $LRPT_LOG 2>&1; then
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-spectrogram.png" "${IMAGE_THUMB_BASE}-spectrogram.png" >> $LRPT_LOG 2>&1
    log "Spectrogram saved to ${IMAGE_FILE_BASE}-spectrogram.png" "INFO"
  else
    log "Spectrogram could not be drawn" "WARN"
  fi
fi
CADU_FILE="$WORK_DIR/meteor_m2-x_lrpt${mode}.cadu"

log "Removing old bmp, gcp, and dat files" "INFO"
find "$LRPT_HOME/tmp/meteor" -type f \( -name "*.gcp" -o -name "*.bmp" -o -name "*.dat" \) -mtime +1 -delete >> $LRPT_LOG 2>&1

if [[ "$METEOR_DECODER" == "meteordemod" ]]; then
  log "Running MeteorDemod to demodulate OQPSK file, rectify (spread) images, create heat map and composites and convert them to JPG" "INFO"
  if [[ "$METEOR_${SAT_NUMBER}_80K_INTERLEAVING" == "true" ]]; then
    $METEORDEMOD -m oqpsk -diff 1 -int 1 -s 80000 -sat $SAT_NAME_METEORDEMOD -t "$TLE_FILE" -f jpg -i "${CADU_FILE}" -o "$LRPT_HOME/tmp/meteor"  >> $LRPT_LOG 2>&1
  else
    $METEORDEMOD -m oqpsk -diff 1 -s 72000 -sat $SAT_NAME_METEORDEMOD -t "$TLE_FILE" -f jpg -i "${CADU_FILE}" -o "$LRPT_HOME/tmp/meteor" >> $LRPT_LOG 2>&1
  fi

  log "Waiting for files to close" "INFO"
  sleep 2

  # for i in -o $LRPT_HOME/tmp/meteor/spread_*.jpg; do
  #   $CONVERT -quality 100 $FLIP "$i" "$i" >> $LRPT_LOG 2>&1
  # done

  for file in $LRPT_HOME/tmp/meteor/*.jpg; do
    new_filename=$(echo "$file" | sed -E 's/_([0-9]+-[0-9]+-[0-9]+-[0-9]+-[0-9]+-[0-9]+)//')        #This part removes unecessary numbers from the MeteorDemod image names using RegEx
    mv "$file" "$new_filename"
    image_filename=$(basename "$new_filename")

    ${IMAGE_PROC_DIR}/meteor_normalize_annotate.sh "$new_filename" "${IMAGE_FILE_BASE}-${image_filename%.jpg}.jpg" $METEOR_IMAGE_QUALITY >> $LRPT_LOG 2>&1
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-${image_filename%.jpg}.jpg" "${IMAGE_THUMB_BASE}-${image_filename%.jpg}.jpg" >> $LRPT_LOG 2>&1
    rm "$new_filename"
  done


elif [[ "$METEOR_DECODER" == "satdump" ]]; then
  # keep the product (raw channels, line times, orbit) for the daily map, before it is deleted
  save_daily_product . "$FILENAME_BASE" "$EPOCH_START"
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


else
  echo "Unknown decoder: $METEOR_DECODER"
fi

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
  $SQLITE3 $DB_FILE "INSERT OR REPLACE INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, has_spectrogram, has_polar_az_el, has_polar_direction, gain) \
                                      VALUES ($EPOCH_START, \"$FILENAME_BASE\", $daylight, 0, $spectrogram, $polar_az_el, $polar_direction, $GAIN);" >> $LRPT_LOG 2>&1

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
else
  log "No images found" "INFO"
fi

rm -f "${SPECTRO_DATA}"

# calculate and report total time for capture
TIMER_END=$(date '+%s')
DIFF=$(($TIMER_END - $TIMER_START))
PROC_TIME=$(date -ud "@$DIFF" +'%H:%M.%S')
log "Total processing time: ${PROC_TIME}" "INFO"
