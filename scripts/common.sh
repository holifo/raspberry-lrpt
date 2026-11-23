#!/bin/bash
#
# Purpose: Common code that is likely loaded in most of the scripts
#          within this framework. Handles things such as a start date/time,
#          logging, and other various "common" functionality.

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
log_level=${LOG_LEVEL}

# log function
log() {
  local log_message=$1
  local log_priority=$2

  # check if level exists and is of the right level to log
  [[ ${levels[$log_priority]} ]] || return 1
  (( ${levels[$log_priority]} < ${levels[$log_level]} )) && return 2

  # log in place (which for at jobs end up in the linux mail)
  echo "${log_priority} : ${log_message}"

  # log output to a log file
  echo $(date '+%d-%m-%Y %H:%M') $0 "${log_priority} : ${log_message}" >> "$LRPT_LOG"
}

# run as a normal user for any scripts within
if [ $EUID -eq 0 ]; then
  log "This script shouldn't be run as root." "ERROR"
  exit 1
fi

# binary helpers
CONVERT="/usr/bin/convert"
FFMPEG="/usr/bin/ffmpeg"
SOX="/usr/bin/sox"
GMIC="/usr/bin/gmic"
IDENTIFY="/usr/bin/identify"
PREDICT="/usr/bin/predict"
RTL_FM="$(command -v rtl_fm || echo /usr/bin/rtl_fm)"
SQLITE3="/usr/bin/sqlite3"
SATDUMP="/usr/bin/satdump"

# base directories for scripts
SCRIPTS_DIR="${LRPT_HOME}/scripts"
AUDIO_PROC_DIR="${SCRIPTS_DIR}/audio_processors"
IMAGE_PROC_DIR="${SCRIPTS_DIR}/image_processors"

# a capture script that is running (its process, not an editor or a shell that mentions it)
METEOR_RUNNING='^(/usr)?/bin/bash [^ ]*/receive_meteor\.sh '
ISS_RUNNING='^(/usr)?/bin/bash [^ ]*/receive_iss\.sh '

# frequency ranges for objects
METEOR_M2_3_FREQ="137.9000"
METEOR_M2_4_FREQ="137.9000"
ELEKTRO_L3_FREQ="1691.0000"
ISS_FREQ="${ISS_SSTV_FREQ:-437.5500}"
ISS_APRS_FREQ="${ISS_APRS_FREQ:-437.825}"   # ARISS APRS digipeater (packet, 1200 baud AFSK): iss_aprs_frequency
ISS_SDR_MARK="${LRPT_HOME}/tmp/iss-sdr"    # while the ISS records: "<index> <dedicated|shared>"

# the RTL-SDR the ISS records with: prints "<index> <mode>", mode dedicated (its own dongle, records
# alongside the Meteors), shared (the Meteors' dongle: Meteor passes come first) or none ("- none")
iss_sdr() {
  local meteor=0
  [ "$USE_DEVICE_STRING" == "true" ] && meteor="${METEOR_M2_3_SDR_DEVICE_ID:-0}"
  python3 "$LRPT_HOME/scripts/tools/rtlsdr_list.py" pick "${ISS_SDR_DEVICE:-}" "$meteor" "${RECEIVER_TYPE:-rtlsdr}" 2>> "${LRPT_LOG:-/dev/null}" ||
    echo "- none"
}

# sdr_roles: JSON list of the RTL-SDRs with each one's role (meteor, iss, meteor+iss, spare), as
# schedule.sh saves it for the Live log ($IMAGE_OUTPUT/sdr.json)
sdr_roles() {
  local meteor=0
  [ "$USE_DEVICE_STRING" == "true" ] && meteor="${METEOR_M2_3_SDR_DEVICE_ID:-0}"
  python3 "$LRPT_HOME/scripts/tools/rtlsdr_list.py" roles "${ISS_SDR_DEVICE:-}" "$meteor" \
    "${RECEIVER_TYPE:-rtlsdr}" "${ISS_SSTV:-false}"
}

# the pass's start time: set once, by the script that starts the pass (receive_meteor.sh,
# reprocess_meteor.sh); helpers that source this file later keep it
export START_DATE=${START_DATE:-$(date '+%d-%m-%Y %H:%M')}

# throttle: call right after starting a background job (cmd &); waits while PARALLEL_JOBS of this
# shell's jobs are running, so loops use every core of the Pi without overloading it. Finish the
# loop with a plain `wait`.
PARALLEL_JOBS=${PARALLEL_JOBS:-$(nproc 2>/dev/null || echo 2)}
throttle() {
  while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL_JOBS" ]; do wait -n 2>/dev/null || break; done
}

# tle_file_ok FILE: true when FILE holds TLEs for both Meteors (name line, then lines 1 and 2)
tle_file_ok() {
  [ -s "$1" ] && grep -A1 '^METEOR-M2 3' "$1" | grep -q '^1 57166' && grep -A1 '^METEOR-M2 4' "$1" | grep -q '^1 59051'
}

# save_daily_product DIR BASE EPOCH: keep a pass's SatDump product (product.cbor and the raw
# channel images) in $METEOR_AUDIO_OUTPUT/products/BASE for the daily map (daily_map.sh).
# Only passes whose decode had an orbit and sane line times (a map was drawn) are kept.
save_daily_product() {
  local src="$1/MSU-MR (Filled)" dst="$METEOR_AUDIO_OUTPUT/products/$2"
  [ "${DAILY_MAP:-false}" = "true" ] || return 0
  [ -f "$src/product.cbor" ] && ls "$src"/*map.png >/dev/null 2>&1 && satdump_times_ok "$1" "$3" || return 0
  mkdir -p "$dst" && cp "$src/product.cbor" "$src"/MSU-MR-*.png "$dst"/ 2>/dev/null
}

# daily_map_later EPOCH: rebuild the daily map of the pass's (local) day in the background
daily_map_later() {
  [ "${DAILY_MAP:-false}" = "true" ] || return 0
  # in a subshell, so it is not a job of this shell (a later `wait` or `throttle` won't wait for it)
  ( setsid nohup nice -n 19 "$LRPT_HOME/scripts/daily_map.sh" "$(date -d "@$1" +%F)" >/dev/null 2>&1 </dev/null & )
}

# satdump_times_ok DIR EPOCH: true when the SatDump decode in DIR has line times within an
# hour of the pass (EPOCH). The map overlay, projections and MCIR are drawn from those
# times; corrupt frames (a weak or noisy pass) can carry nonsense ones, and then the
# coastlines land somewhere else entirely.
satdump_times_ok() {
  local t
  t=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["timestamp"]))' "$1/dataset.json" 2>/dev/null) || return 0
  [ $(( t > $2 ? t - $2 : $2 - t )) -lt 3600 ]
}

# work_dir NAME: make a scratch folder for one decode and print its path. With storage: sd it is
# on the RAM disk ($RAMFS_AUDIO), which spares the SD card the ~250 MB of images a decode writes,
# as long as the RAM disk is mounted and both it and the Pi's free memory have WORK_RAM_MB
# (600 MB) to spare. Otherwise (storage: ssd, or no room) it is in $LRPT_HOME/tmp.
work_dir() {
  local base="$LRPT_HOME/tmp" need=${WORK_RAM_MB:-600} room avail
  if [ "${STORAGE:-sd}" = "sd" ] && [ -n "$RAMFS_AUDIO" ] && mountpoint -q "$RAMFS_AUDIO" 2>/dev/null; then
    room=$(df -Pm "$RAMFS_AUDIO" | awk 'NR == 2 { print $4 }')
    avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
    if [ "${room:-0}" -ge "$need" ] && [ "${avail:-0}" -ge "$need" ]; then base="$RAMFS_AUDIO"; fi
  fi
  mkdir -p "$base" && mktemp -d "$base/$1.XXXXXX"
}

# pass_clear SECONDS: true when no pass is being recorded or processed and no scheduled pass
# starts within SECONDS. Heavy jobs (re-processing) wait for it, so they never take the CPU
# and memory a live decode needs.
pass_clear() {
  local now; now=$(date +%s)
  pgrep -f "^(/usr)?/bin/bash [^ ]*/receive_(meteor|iss)\.sh " >/dev/null 2>&1 && return 1
  [ -n "$($SQLITE3 "$DB_FILE" "SELECT 1 FROM predict_passes WHERE is_active = 1
        AND pass_start < $((now + ${1:-900})) AND pass_end > $now LIMIT 1;" 2>/dev/null)" ] && return 1
  return 0
}

# reproject IN OUT W N E S [extra args]: turn an equirectangular map covering W N E S into the
# map_projection (equal_earth: image_processors/equal_earth.py); with equirectangular, or if the
# warp fails, OUT is IN unchanged. Prints the size of OUT (WxH).
reproject() {
  local in=$1 out=$2 w=$3 n=$4 e=$5 s=$6; shift 6
  if [ "${MAP_PROJECTION:-equal_earth}" = "equal_earth" ] &&
     python3 "$LRPT_HOME/scripts/image_processors/equal_earth.py" "$in" "$out.tmp.${out##*.}" --bounds "$w" "$n" "$e" "$s" "$@" >/dev/null 2>>"$LRPT_LOG"; then
    mv -f "$out.tmp.${out##*.}" "$out"
  else
    rm -f "$out.tmp.${out##*.}"
    [ "${MAP_PROJECTION:-equal_earth}" = "equal_earth" ] && log "Equal Earth warp failed for $in - kept as equirectangular" "WARN"
    [ "$in" = "$out" ] || cp -f "$in" "$out"
  fi
  $CONVERT "$out" -format '%wx%h' info: 2>/dev/null
}

# discord_pass FILE_BASE DAYLIGHT SAT_NAME EPOCH_START MAX_ELEV DIRECTION SECONDS PASS_ID [--wait]
#   Posts one pass to Discord (discord_webhook in settings): a short message, the first
#   DISCORD_IMAGES full-size images in the order of the day or night thumbnail list, then the
#   day or night image list, and the sky track. Detached unless --wait. Returns 1 when the pass
#   has no images left (or Discord is off).
discord_pass() {
  local base=$1 day=$2 sat=$3 start=$4 elev=$5 dir=$6 secs=$7 id=$8 wait=$9
  [ -n "${DISCORD_WEBHOOK}" ] || return 1
  local order day_word name f
  if [ "$sat" == "ISS-APRS" ]; then      # an APRS pass: its map and the station count
    local n
    n=$($SQLITE3 "$DB_FILE" "SELECT img_count FROM decoded_passes WHERE id = '${id}';" 2>/dev/null)
    [ -f "${IMAGE_OUTPUT}/${base}-aprs-map.png" ] || return 1
    local amsg="📡 **ISS** APRS · $(date -d "@$start" '+%d/%m/%Y %H:%M') ($(date -u -d "@$start" '+%H:%M') UTC)
${n:-?} station(s) heard through the ISS on ${ISS_APRS_FREQ} MHz · max elevation ${elev}°
${STATION_TITLE}"
    [ -n "${DISCORD_SITE_URL}" ] && amsg="${amsg}
${DISCORD_SITE_URL%/}/captures/listImages?pass_id=${id}"
    log "Posting ${base} (APRS) to Discord" "INFO"
    if [ "$wait" == "--wait" ]; then
      "$LRPT_HOME/scripts/push_discord.sh" "$amsg" "${IMAGE_OUTPUT}/${base}-aprs-map.png"
    else
      ( nohup "$LRPT_HOME/scripts/push_discord.sh" "$amsg" "${IMAGE_OUTPUT}/${base}-aprs-map.png" > /dev/null 2>&1 & )
    fi
    return 0
  fi
  if [ "$sat" == "ISS" ]; then
    order=$(cd "${IMAGE_OUTPUT}" && ls "${base}"-SSTV_*.jpg 2>/dev/null | sed "s/^${base}-//; s/\.jpg$//" | sort -t_ -k2n | tr '\n' ' ')
    day_word="SSTV pictures"
  elif [ "$day" == "1" ]; then
    order="${METEOR_DAY_THUMBNAIL} ${METEOR_DAY_ENHANCEMENTS}"; day_word="day pass"
  else
    order="${METEOR_NIGHT_THUMBNAIL} ${METEOR_NIGHT_ENHANCEMENTS}"; day_word="night pass"
  fi
  local files=()
  for name in $order; do
    [ ${#files[@]} -ge "${DISCORD_IMAGES:-2}" ] && break
    f="${IMAGE_OUTPUT}/${base}-${name}.jpg"
    [ -f "$f" ] && [[ ! " ${files[*]} " == *" $f "* ]] && files+=("$f")
  done
  if [ ${#files[@]} -eq 0 ] && [ "${DISCORD_IMAGES:-2}" -gt 0 ]; then
    for f in "${IMAGE_OUTPUT}/${base}"-*_corrected.jpg; do    # none of the listed ones: any image
      [ -f "$f" ] && { files+=("$f"); break; }
    done
  fi
  [ ${#files[@]} -eq 0 ] && [ "${DISCORD_IMAGES:-2}" -gt 0 ] && return 1
  if [ "${DISCORD_SKY_TRACK}" == "true" ] && [ -f "${IMAGE_OUTPUT}/${base}-polar-direction.png" ]; then
    files+=("${IMAGE_OUTPUT}/${base}-polar-direction.png")
  fi
  local dir_part="" secs_part=""
  case "${dir,,}" in northbound|southbound) dir_part=" · ${dir,,}" ;; esac
  [ "${secs:-0}" -gt 0 ] 2>/dev/null && secs_part=" · $((secs / 60)) min"
  local msg="🛰️ **${sat}** · $(date -d "@$start" '+%d/%m/%Y %H:%M') ($(date -u -d "@$start" '+%H:%M') UTC)
Max elevation ${elev}°${dir_part} · ${day_word}${secs_part}
${STATION_TITLE}"
  [ -n "${DISCORD_SITE_URL}" ] && msg="${msg}
${DISCORD_SITE_URL%/}/captures/listImages?pass_id=${id}"
  log "Posting ${base} to Discord (${#files[@]} image(s))" "INFO"
  if [ "$wait" == "--wait" ]; then
    "$LRPT_HOME/scripts/push_discord.sh" "$msg" "${files[@]}"
  else
    ( nohup "$LRPT_HOME/scripts/push_discord.sh" "$msg" "${files[@]}" > /dev/null 2>&1 & )
  fi
}

# drop_dark_images DIR: delete the images made from a channel with no picture in it (night passes:
# channels 1-3 need sunlight), checked against the raw MSU-MR-N.png channels in DIR. Setting
# drop_dark_images; it never fails the pass.
drop_dark_images() {
  [ "${DROP_DARK_IMAGES:-true}" == "true" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && log "$line" "INFO"
  done < <(python3 "$LRPT_HOME/scripts/image_processors/drop_dark_images.py" "$1" 2>&1)
  return 0
}

# rain_images DIR DAYLIGHT [FLIP]: setting rain_images (FLIP true: a northbound pass that is turned
# 180° afterwards, so the legend is drawn upside down to end up upright). Night passes get the relative "Coldest cloud tops"
# image from channel 4 (cold_tops.py; the satellites send no calibration now, so no temperatures).
# SatDump's own "Rain Likelihood" composites (configs.yml) appear by themselves when calibration
# comes back; the 3.7 um one is dropped by day, when that channel also sees reflected sunlight.
rain_images() {
  [ "${RAIN_IMAGES:-true}" == "true" ] || return 0
  local dir=$1 line ch4="$1/msu_mr_MSU-MR_Channel_4_corrected.png"
  if [ "$2" == "1" ]; then
    rm -f "$dir"/*Rain_Likelihood_\(3.7_um_night\)*
  elif [ -f "$ch4" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && log "$line" "INFO"
    done < <(python3 "$LRPT_HOME/scripts/image_processors/cold_tops.py" "$ch4" "$dir/msu_mr_rgb_Cold_Cloud_Tops_corrected.png" \
               $([ "${3:-false}" == "true" ] && echo --flip) 2>&1)
  fi
  return 0
}

# capitals_map DIR DAYLIGHT EPOCH: the whole pass projected north up with the borders, the station
# and the capitals' names (green: SatDump's default_cities_color, set by Ansible), MSA by day and
# MCIR at night, as DIR/msu_mr_Capitals_map_projected.png, which the label/thumbnail loop then
# picks up like the others. SatDump can't fit a projection to the pass by itself, so it projects
# onto a box wide enough for any pass heard here (90° x 75° around the station, 0.025°/px) and
# crop_to_swath.py cuts that down to the pass (the borders and names drawn outside it don't
# count). With capitals_map_area ("west east south north") it projects that area at 0.01°/px
# instead. Only with a map (orbit known) and line times that fit the pass. Never fails the pass.
capitals_map() {
  [ "${CAPITALS_MAP:-true}" == "true" ] || return 0
  local dir=$1 comp=MCIR out="$1/msu_mr_Capitals_map_projected.png" w e s n res tmp line
  [ -f "$dir/product.cbor" ] && ls "$dir"/*map.png >/dev/null 2>&1 || return 0
  satdump_times_ok "$(dirname "$dir")" "$3" || return 0
  [ "$2" == "1" ] && comp=MSA
  read -r w e s n <<< "${CAPITALS_MAP_AREA:-}"
  if [ -n "$n" ]; then
    res=0.01
  else
    # the whole pass: a box around the station, cropped to the pass afterwards
    read -r w e s n <<< "$(awk -v la="$LAT" -v lo="$LON" 'BEGIN {
      s = la - 35; n = la + 40; if (s < -85) s = -85; if (n > 85) n = 85
      printf "%.2f %.2f %.2f %.2f", lo - 45, lo + 45, s, n }')"
    res=0.025
  fi
  tmp="$dir/capitals_map.tmp.png"
  nice -n 10 $SATDUMP project -layer --type product --file "$dir/product.cbor" --composite "$comp" \
    -target --type equirec --offset_x "$w" --offset_y "$n" --scalar_x "$res" --scalar_y "-$res" \
            --width "$(awk -v a="$w" -v b="$e" -v r="$res" 'BEGIN{printf "%d", (b-a)/r}')" \
            --height "$(awk -v a="$s" -v b="$n" -v r="$res" 'BEGIN{printf "%d", (b-a)/r}')" \
            --draw_map_overlay --draw_qth_overlay \
            --draw_cities_overlay --cities_type 0 --cities_scale_rank 3 --cities_size 24 \
            --file "$tmp" >> "$LRPT_LOG" 2>&1
  if [ -s "$tmp" ]; then
    while IFS= read -r line; do [ -n "$line" ] && log "$line" "INFO"; done < <(
      python3 "$LRPT_HOME/scripts/image_processors/crop_to_swath.py" "$tmp" "$out" \
        $([ -n "${CAPITALS_MAP_AREA:-}" ] && echo --keep) 2>&1)
  fi
  [ -s "$out" ] || log "Capitals map ($comp): none made" "INFO"
  rm -f "$tmp"
  return 0
}

# pass_fail_reason SNR_PEAK LOCKED_S RAN_S CAPTURE_TIME: why a Meteor pass gave no images, as one
# word for the Passes page (the numbers come from the spectrogram recorder; NULL when it didn't run):
#   receiver   SatDump stopped long before the pass ended (receiver missing or busy, a crash)
#   no_signal  no signal above the noise (peak SNR under 3 dB): antenna, cable, LNA or a low pass
#   no_lock    a signal, but the decoder never locked on to it (too weak or interference)
#   too_short  the decoder locked, but not long enough for a picture
#   no_images  none of the above fits (no signal numbers, e.g. spectrogram off)
pass_fail_reason() {
  local snr=$1 locked=$2 ran=$3 capture=$4
  if [ -n "$ran" ] && [ -n "$capture" ] && [ "$capture" -gt 0 ] && [ "$ran" -lt $((capture / 2)) ]; then
    echo receiver
  elif [ "$locked" = "NULL" ] || [ -z "$locked" ]; then
    echo no_images
  elif [ "$locked" -gt 0 ]; then
    echo too_short
  elif awk -v s="$snr" 'BEGIN { exit !(s + 0 < 3) }'; then
    echo no_signal
  else
    echo no_lock
  fi
}
