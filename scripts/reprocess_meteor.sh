#!/bin/bash
#
# Re-process kept recordings offline and publish them on the web panel.
#
# The station keeps the decoded frames (.cadu) of the last passes in /srv/audio/meteor
# (keep_recordings). This script runs SatDump on them again, offline, then does what a live
# pass does after decoding: rotate northbound passes, annotate, thumbnails, pass graphs and the
# database row, so the pass shows (again) under Captures.
#
# Usage (on the Pi, as the normal user):
#   ./scripts/reprocess_meteor.sh              list the recordings and ask which to process
#   ./scripts/reprocess_meteor.sh -l           only list them
#   ./scripts/reprocess_meteor.sh 2 3          process recordings 2 and 3 from the list
#   ./scripts/reprocess_meteor.sh all          process every recording
#   ./scripts/reprocess_meteor.sh -a           process every recording that isn't on the site yet
#   ./scripts/reprocess_meteor.sh FILE.cadu    process one file (any folder)
#   -y                                         don't ask before replacing a capture that exists
#
# Everything is logged to the station log as well.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else B=; G=; Y=; R=; D=; N=; fi
say()  { echo "${B}==>${N} $*"; log "reprocess: $*" "INFO" >/dev/null; }
warn() { echo "  ${Y}!!${N} $*"; log "reprocess: $*" "WARN" >/dev/null; }
fail() { echo "  ${R}xx${N} $*" >&2; log "reprocess: $*" "ERROR" >/dev/null; }

LIST_ONLY=false; ALL_NEW=false; YES=false; PICKS=()
for a in "$@"; do
  case "$a" in
    -l) LIST_ONLY=true ;;
    -a) ALL_NEW=true ;;
    -y) YES=true ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option $a (see -h)"; exit 1 ;;
    *) PICKS+=("$a") ;;
  esac
done
[ $EUID -eq 0 ] && { echo "Run it as your normal user, not with sudo"; exit 1; }
pgrep -f "satdump live" >/dev/null && { echo "A pass is being recorded now - try again after it has been processed"; exit 1; }

# ---- what is there ------------------------------------------------------------------------
mapfile -t FILES < <(ls -1t "$METEOR_AUDIO_OUTPUT"/*.cadu 2>/dev/null)

base_info() {   # METEOR-M2-4-20261112-013220 -> "METEOR-M2 4|<utc epoch>"
  local b; b=$(basename "$1" .cadu)
  [[ "$b" =~ ^METEOR-M2-([0-9])-([0-9]{8})-([0-9]{6})$ ]] || return 1
  local d=${BASH_REMATCH[2]} t=${BASH_REMATCH[3]}
  echo "METEOR-M2 ${BASH_REMATCH[1]}|$(date -u -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s)"
}
on_site() { [ -n "$($SQLITE3 "$DB_FILE" "SELECT id FROM decoded_passes WHERE file_path = '$1' LIMIT 1;")" ]; }

list() {
  if [ ${#FILES[@]} -eq 0 ]; then echo "No recordings in $METEOR_AUDIO_OUTPUT"; return 1; fi
  echo "${B}Recordings in $METEOR_AUDIO_OUTPUT${N} (times are local)"
  local i=0 f b info sat ep state
  for f in "${FILES[@]}"; do
    i=$((i + 1)); b=$(basename "$f" .cadu)
    if info=$(base_info "$f"); then
      sat=${info%%|*}; ep=${info##*|}
      if on_site "$b"; then
        if [ -n "$(ls "$IMAGE_OUTPUT"/"$b"-*corrected*.jpg 2>/dev/null | head -1)" ]; then state="${G}on the site${N}"; else state="${Y}on the site, no images${N}"; fi
      else state="${D}not on the site${N}"; fi
      printf "  %2d  %-12s %s  %6s  %s\n" "$i" "${sat#METEOR-}" "$(date -d "@$ep" '+%a %d/%m %H:%M')" "$(du -h "$f" | cut -f1)" "$state"
    else
      printf "  %2d  %s  %6s  %s\n" "$i" "$b" "$(du -h "$f" | cut -f1)" "(name not recognised)"
    fi
  done
}

# ---- one recording --------------------------------------------------------------------------
process() {
  local cadu="$1" base info
  base=$(basename "$cadu" .cadu)
  info=$(base_info "$cadu") || { fail "$base: the name isn't METEOR-M2-N-YYYYMMDD-HHMMSS.cadu"; return 1; }
  export SAT_NAME=${info%%|*}
  local file_epoch=${info##*|}

  # the pass it belongs to, from the schedule (closest start within 15 minutes)
  local row
  row=$($SQLITE3 -separator '|' "$DB_FILE" "SELECT pass_start, pass_end, max_elev, direction, azimuth_at_max
        FROM predict_passes WHERE sat_name = '$SAT_NAME' AND abs(pass_start - $file_epoch) < 900
        ORDER BY abs(pass_start - $file_epoch) LIMIT 1;")
  local epoch_start end
  if [ -n "$row" ]; then
    IFS='|' read -r epoch_start end SAT_MAX_ELEVATION PASS_DIRECTION az_max <<< "$row"
  else
    warn "$base: no matching pass in the schedule - using the file's time, no pass graphs"
    epoch_start=$file_epoch; end=$((file_epoch + 900)); SAT_MAX_ELEVATION=0; PASS_DIRECTION=""; az_max=""
  fi
  export SAT_MAX_ELEVATION PASS_DIRECTION
  export PASS_SIDE=W
  [ -n "$az_max" ] && [ "${az_max%.*}" -ge 0 ] && [ "${az_max%.*}" -le 180 ] && PASS_SIDE=E

  if [ "$SAT_NAME" == "METEOR-M2 3" ]; then
    export GAIN=$METEOR_M2_3_GAIN SUN_MIN_ELEV=$METEOR_M2_3_SUN_MIN_ELEV SAT_MIN_ELEV=$METEOR_M2_3_SAT_MIN_ELEV
  else
    export GAIN=$METEOR_M2_4_GAIN SUN_MIN_ELEV=$METEOR_M2_4_SUN_MIN_ELEV SAT_MIN_ELEV=$METEOR_M2_4_SAT_MIN_ELEV
  fi
  export START_DATE; START_DATE=$(date -d "@$epoch_start" '+%d-%m-%Y %H:%M')
  export SUN_ELEV; SUN_ELEV=$(python3 "$SCRIPTS_DIR/tools/sun.py" $((epoch_start + 90)))
  local daylight=0; [ "${SUN_ELEV}" -gt "${SUN_MIN_ELEV}" ] && daylight=1

  say "$base: $SAT_NAME, $(date -d "@$epoch_start" '+%d/%m %H:%M'), ${SAT_MAX_ELEVATION}° ${PASS_DIRECTION}, $([ $daylight = 1 ] && echo day || echo night)"

  local image_base="$IMAGE_OUTPUT/$base" thumb_base="$IMAGE_OUTPUT/thumb/$base"
  if on_site "$base" || ls "$image_base"-*.jpg >/dev/null 2>&1; then
    if ! $YES; then
      read -r -p "  $base is already on the site. Replace its images? [y/N] " ans < /dev/tty
      [[ "$ans" =~ ^[Yy] ]] || { echo "  skipped"; return 0; }
    fi
  fi

  # decode again, offline, in a scratch folder
  local work; work=$(work_dir reprocess)   # on the RAM disk with storage: sd, when it has room
  echo "  decoding with SatDump (a few minutes on a Pi)..."
  # SatDump's exit code isn't reliable: what counts is the images it writes
  (cd "$work" && $SATDUMP meteor_m2-x_lrpt cadu "$cadu" "$work" --fill_missing >> "$LRPT_LOG" 2>&1)
  # SatDump writes the images twice: first in MSU-MR, then (gaps filled) in "MSU-MR (Filled)".
  # Use the filled set when it is complete, otherwise whichever folder has more of them.
  local dir="$work/MSU-MR (Filled)" n_filled n_plain
  n_filled=$(ls "$work/MSU-MR (Filled)"/*corrected*.png 2>/dev/null | wc -l)
  n_plain=$(ls "$work/MSU-MR"/*corrected*.png 2>/dev/null | wc -l)
  [ "$n_plain" -gt "$n_filled" ] && dir="$work/MSU-MR"
  [ "$n_filled" -lt "$n_plain" ] && warn "$base: SatDump stopped before the gap-filled images; using the plain ones"
  if ! ls "$dir"/*.png >/dev/null 2>&1; then
    fail "$base: SatDump made no images - the recording may hold too little signal"
    rm -rf "$work"; return 1
  fi

  # keep the product for the daily map, then the same clean-up and naming as a live pass
  save_daily_product "$work" "$base" "$epoch_start"
  drop_dark_images "$dir"
  rain_images "$dir" "$daylight"
  find "$dir" -type f -name "*.png" ! -name "*projected*" ! -name "*corrected*" -delete
  local f
  for f in "$dir"/rgb_msu_mr_rgb_*_projected.png; do
    [ -e "$f" ] || continue
    local c="${f/rgb_msu_mr_rgb_/msu_mr_rgb_}"; c="${c/_projected.png/_corrected.png}"
    [ -e "$c" ] || rm -f "$f"
  done
  if satdump_times_ok "$work" "$epoch_start"; then
    for f in "$dir"/*map.png; do [ -e "$f" ] && mv "$f" "${f/_map.png/.png}"; done
  else
    # corrupt frames with nonsense times: a map would be drawn in the wrong place
    warn "$base: the recording's line times are hours away from the pass (corrupt data) - no map overlay"
    rm -f "$dir"/*map.png "$dir"/*projected*.png "$dir"/*MCIR*.png
  fi
  if [ "$PASS_DIRECTION" == "Northbound" ] && [ "$FLIP_METEOR_IMG" == "true" ]; then
    for f in "$dir"/*_corrected.png; do [ -e "$f" ] || continue; $CONVERT "$f" -rotate 180 "$f" >> "$LRPT_LOG" 2>&1 & throttle; done
    wait
  fi

  rm -f "$image_base"-*corrected*.jpg "$image_base"-*projected*.jpg "$thumb_base"-*corrected*.jpg "$thumb_base"-*projected*.jpg
  local n=0 name
  for f in "$dir"/*.png; do      # several images at once (PARALLEL_JOBS, one per core)
    [ -e "$f" ] || continue
    name=$(basename "$f" .png)
    name="${name#msu_mr_rgb_}"; name="${name#rgb_msu_mr_rgb_}"; name="${name#rgb_msu_mr_}"; name="${name#msu_mr_}"
    { "$IMAGE_PROC_DIR/meteor_normalize_annotate.sh" "$f" "$image_base-$name.jpg" "$METEOR_IMAGE_QUALITY" &&
      "$IMAGE_PROC_DIR/thumbnail.sh" 300 "$image_base-$name.jpg" "$thumb_base-$name.jpg"; } >> "$LRPT_LOG" 2>&1 &
    throttle
  done
  wait
  for f in "$image_base"-*corrected*.jpg "$image_base"-*projected*.jpg; do [ -f "$f" ] && n=$((n + 1)); done
  rm -rf "$work"
  [ $n -gt 0 ] || { fail "$base: no images could be written"; return 1; }
  echo "  ${G}ok${N}  $n images"

  # card thumbnail: the day or night preference, then the first corrected image
  local pref; [ $daylight = 1 ] && pref="$METEOR_DAY_THUMBNAIL" || pref="$METEOR_NIGHT_THUMBNAIL"
  local t picked=""
  for t in $pref; do [ -f "$thumb_base-$t.jpg" ] && { picked="$thumb_base-$t.jpg"; break; }; done
  [ -n "$picked" ] || picked=$(ls "$thumb_base"-*_corrected.jpg 2>/dev/null | head -1)
  [ -n "$picked" ] && cp "$picked" "$thumb_base-website-thumbnail.jpg"

  # pass graphs (only with the pass from the schedule)
  local az_el=0 direction=0 spectro=0
  if [ -n "$row" ] && [ -f "$LRPT_HOME/tmp/orbit.tle" ]; then
    if [ "$PRODUCE_POLAR_AZ_EL" == "true" ]; then
      python3 "$IMAGE_PROC_DIR/polar_plot.py" "$SAT_NAME" "$LRPT_HOME/tmp/orbit.tle" "$epoch_start" "$end" "$LAT" "$LON" \
        "$SAT_MIN_ELEV" "$PASS_DIRECTION" "$image_base-polar-azel.jpg" azel >> "$LRPT_LOG" 2>&1 &&
        "$IMAGE_PROC_DIR/thumbnail.sh" 300 "$image_base-polar-azel.jpg" "$thumb_base-polar-azel.jpg" >> "$LRPT_LOG" 2>&1 && az_el=1
    fi
    if [ "$PRODUCE_POLAR_DIRECTION" == "true" ]; then
      python3 "$IMAGE_PROC_DIR/polar_plot.py" "$SAT_NAME" "$LRPT_HOME/tmp/orbit.tle" "$epoch_start" "$end" "$LAT" "$LON" \
        "$SAT_MIN_ELEV" "$PASS_DIRECTION" "$image_base-polar-direction.png" direction >> "$LRPT_LOG" 2>&1 &&
        "$IMAGE_PROC_DIR/thumbnail.sh" 300 "$image_base-polar-direction.png" "$thumb_base-polar-direction.png" >> "$LRPT_LOG" 2>&1 && direction=1
    fi
  fi
  [ -f "$image_base-spectrogram.png" ] && spectro=1

  # database: replace this recording's row, mark the scheduled pass as captured
  $SQLITE3 "$DB_FILE" "DELETE FROM decoded_passes WHERE file_path = '$base';
    INSERT INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, img_count, has_spectrogram,
                                has_polar_az_el, has_polar_direction, gain)
    VALUES ($epoch_start, '$base', $daylight, 0, $n, $spectro, $az_el, $direction, $GAIN);
    UPDATE predict_passes SET is_active = 0 WHERE pass_start = $epoch_start;" >> "$LRPT_LOG" 2>&1 \
    || { fail "$base: the database update failed"; return 1; }
  local id; id=$($SQLITE3 "$DB_FILE" "SELECT id FROM decoded_passes WHERE file_path = '$base' LIMIT 1;")
  echo "  ${G}ok${N}  published: /captures/listImages?pass_id=$id"
  # the daily maps are redrawn once at the end, not while the next recording decodes
  if [ "${DAILY_MAP:-false}" = "true" ] && [ -d "$METEOR_AUDIO_OUTPUT/products/$base" ]; then
    DAILY_EPOCHS["$(date -d "@$epoch_start" +%F)"]=$epoch_start
  fi
  log "reprocess: $base published as capture $id with $n images" "INFO" >/dev/null
}

# ---- choose -----------------------------------------------------------------------------------
SELECTED=()
if $ALL_NEW; then
  for f in "${FILES[@]}"; do on_site "$(basename "$f" .cadu)" || SELECTED+=("$f"); done
  [ ${#SELECTED[@]} -eq 0 ] && { echo "Every recording is already on the site (see -l)"; exit 0; }
elif [ ${#PICKS[@]} -gt 0 ]; then
  for p in "${PICKS[@]}"; do
    if [ "$p" == "all" ]; then
      SELECTED+=("${FILES[@]}")
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      [ "$p" -ge 1 ] && [ "$p" -le ${#FILES[@]} ] || { echo "No recording number $p (see -l)"; exit 1; }
      SELECTED+=("${FILES[$((p - 1))]}")
    elif [ -f "$p" ]; then
      SELECTED+=("$(readlink -f "$p")")
    else
      echo "Not found: $p (give list numbers, 'all', or a .cadu file; see -l)"; exit 1
    fi
  done
else
  list || exit 1
  $LIST_ONLY && exit 0
  echo
  read -r -p "Process which? (numbers, e.g. 1 3, or 'all'; Enter to stop) " answer < /dev/tty
  [ -z "$answer" ] && exit 0
  if [ "$answer" == "all" ]; then SELECTED=("${FILES[@]}")
  else
    for p in $answer; do
      [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le ${#FILES[@]} ] || { echo "No recording number $p"; exit 1; }
      SELECTED+=("${FILES[$((p - 1))]}")
    done
  fi
fi
$LIST_ONLY && { list; exit 0; }
[ ${#SELECTED[@]} -eq 0 ] && { echo "No recordings in $METEOR_AUDIO_OUTPUT"; exit 0; }

ok_count=0
declare -A DAILY_EPOCHS=()
for f in "${SELECTED[@]}"; do
  echo
  # never decode at the same time as a pass: wait until it is recorded and processed
  if ! pass_clear 900; then
    echo "  ${Y}..${N} a pass is being recorded or starts within 15 minutes - waiting for it to finish"
    log "reprocess: waiting for the current or next pass to finish" "INFO" >/dev/null
    while ! pass_clear 900; do sleep 30; done
  fi
  process "$f" && ok_count=$((ok_count + 1))
done
for day in "${!DAILY_EPOCHS[@]}"; do
  daily_map_later "${DAILY_EPOCHS[$day]}"
  echo "The daily map for $(date -d "$day" '+%d/%m') is being redrawn in the background"
done
echo
echo "${B}Done:${N} $ok_count of ${#SELECTED[@]} processed. See them under Captures in the web panel."
