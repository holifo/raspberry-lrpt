#!/bin/bash
#
# Purpose: Build the daily maps: every pass of one (local) day projected onto one map of the
#          region around the station. Daytime passes make one map (AVHRR 221 false colour),
#          night-time passes another (3.9 µm infrared). The newest pass is drawn on top. Each
#          pass is projected in its own process, one per core, so a day takes about as long as
#          its slowest pass.
#
# Input:   the passes' SatDump products, which receive_meteor.sh and reprocess_meteor.sh keep in
#          $METEOR_AUDIO_OUTPUT/products/<pass> (save_daily_product in common.sh)
# Output:  $IMAGE_OUTPUT/daily/<YYYY-MM-DD>-day.jpg and -night.jpg, thumbnails in daily/thumb,
#          and <YYYY-MM-DD>.json with the passes each map is made of (read by the web panel).
#          A day with no kept products is left as it is.
#
# Usage:   ./daily_map.sh [YYYY-MM-DD]      (default: today; run after each pass by the scripts)
#          ./daily_map.sh --all            redraw every day that still has kept products

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

# --all: every (local) day that still has kept products, one after another
if [ "$1" = "--all" ]; then
  for d in $(ls -1d "$METEOR_AUDIO_OUTPUT/products"/METEOR-M2-* 2>/dev/null | sed -E 's/.*-([0-9]{8})-([0-9]{6})$/\1 \2/' |
             while read -r ymd hms; do date -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2} ${hms:0:2}:${hms:2:2}:${hms:4:2} UTC" +%F; done | sort -u); do
    echo "Redrawing $d"
    "$0" "$d"
  done
  exit 0
fi

day="${1:-$(date +%F)}"
date -d "$day" >/dev/null 2>&1 || { log "Daily map: not a date: $day" "ERROR"; exit 1; }

products="$METEOR_AUDIO_OUTPUT/products"
out="$IMAGE_OUTPUT/daily"
mkdir -p "$out/thumb" "$LRPT_HOME/tmp"

# one run at a time; a second one waits for the first
exec 9>"$LRPT_HOME/tmp/daily_map.lock"
flock 9

# the map: 70° of longitude by 50° of latitude around the station, 0.025° a pixel
lon0=$(awk -v l="$LON" 'BEGIN { printf "%.3f", l - 35 }')
lat0=$(awk -v l="$LAT" 'BEGIN { printf "%.3f", l + 25 }')
width=2800
height=2000
lon1=$(awk -v l="$lon0" 'BEGIN { print l + 70 }')
lat1=$(awk -v l="$lat0" 'BEGIN { print l - 50 }')
map_size="${width}x${height}"

# the day's passes (pass folders are named in UTC, the day is local), newest first
day_layers=(); night_layers=(); day_passes=(); night_passes=()
for dir in $(ls -1d "$products"/METEOR-M2-* 2>/dev/null | sort -r); do
  base=$(basename "$dir")
  [[ "$base" =~ ([0-9]{8})-([0-9]{6})$ ]] || continue
  d=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
  local_day=$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2} UTC" +%F)
  [ "$local_day" = "$day" ] || continue
  [ -f "$dir/product.cbor" ] || continue

  # day or night as the capture page has it; a pass deleted from the site is left out
  daylight=$($SQLITE3 "$DB_FILE" "SELECT daylight_pass FROM decoded_passes WHERE file_path = '$base' ORDER BY id DESC LIMIT 1;" 2>/dev/null)
  [ -n "$daylight" ] || continue

  if [ "$daylight" = "1" ] && [ -f "$dir/MSU-MR-1.png" ] && [ -f "$dir/MSU-MR-2.png" ]; then
    day_layers+=("$dir/product.cbor")
    day_passes+=("$base")
  elif [ "$daylight" != "1" ] && [ -f "$dir/MSU-MR-4.png" ]; then
    night_layers+=("$dir/product.cbor")
    night_passes+=("$base")
  fi
done

# make_map KIND COMPOSITE PRODUCT...: project each pass (products newest first) onto the map in
# its own SatDump process, as many at once as the Pi has cores (SatDump warps one layer on one
# core), without borders, so each layer is just its swath. blend_layers.py then blends them with
# no seams (where passes overlap, the one that saw the spot nearer its swath's middle wins, with a
# soft hand-over) and draws the borders, coastlines, station and capitals once on top, from the
# newest pass projected again with them. Saved as a JPEG with a thumbnail.
make_map() {
  local kind=$1 comp=$2; shift 2
  local jpg="$out/$day-$kind.jpg" work k=0 layers=() stack=()
  work=$(mktemp -d "$LRPT_HOME/tmp/daily-$day-$kind.XXXXXX")
  # capital cities' names (map_capitals), smaller than on the pass images: the map covers 70°
  local capitals=()
  [ "${MAP_CAPITALS:-true}" = "true" ] && capitals=(--draw_cities_overlay --cities_type 0 --cities_scale_rank 3 --cities_size 30)
  local target=(-target --type equirec --offset_x "$lon0" --offset_y "$lat0"
                --scalar_x 0.025 --scalar_y -0.025 --width $width --height $height)
  log "Daily map: projecting $# $kind pass(es) of $day ($comp), $PARALLEL_JOBS at a time" "INFO"
  for prod in "$@"; do
    k=$((k + 1)); layers+=("$work/$k.png")
    $SATDUMP project -layer --type product --file "$prod" --composite "$comp" "${target[@]}" \
      --file "$work/$k.png" > "$work/$k.log" 2>&1 &
    throttle
  done
  # the borders: the newest pass once more, with them
  $SATDUMP project -layer --type product --file "$1" --composite "$comp" "${target[@]}" \
    --draw_map_overlay --draw_qth_overlay "${capitals[@]}" --file "$work/overlay.png" > "$work/overlay.log" 2>&1 &
  throttle
  wait
  cat "$work"/*.log >> "$LRPT_LOG" 2>/dev/null
  for (( k = ${#layers[@]} - 1; k >= 0; k-- )); do [ -s "${layers[k]}" ] && stack+=("${layers[k]}"); done
  if [ ${#stack[@]} -eq 0 ]; then
    log "Daily map: SatDump made no $kind map for $day" "WARN"
    rm -rf "$work"
    return 1
  fi
  local line
  while IFS= read -r line; do [ -n "$line" ] && log "$line" "INFO"; done < <(
    python3 "$LRPT_HOME/scripts/image_processors/blend_layers.py" "$work/blend.png" \
      "$work/overlay.png" "$work/1.png" "${stack[@]}" 2>&1)
  if [ ! -s "$work/blend.png" ]; then
    # blending failed: stack them as before (newest on top)
    log "Daily map: blending failed, stacking the passes instead" "WARN"
    $CONVERT -background '#0b1220' "${stack[@]}" -layers flatten "$work/blend.png" >> "$LRPT_LOG" 2>&1
  fi
  $CONVERT "$work/blend.png" -quality 88 "$jpg" >> "$LRPT_LOG" 2>&1 &&
    map_size=$(reproject "$jpg" "$jpg" "$lon0" "$lat0" "$lon1" "$lat1") &&
    $CONVERT "$jpg" -resize 700x "$out/thumb/$day-$kind.jpg" >> "$LRPT_LOG" 2>&1
  rm -rf "$work"
  log "Daily map: saved $jpg (${#stack[@]} of $# passes)" "INFO"
}

json_list() { local first=1; printf '['; for p in "$@"; do [ $first = 1 ] || printf ','; printf '"%s"' "$p"; first=0; done; printf ']'; }

# nothing kept for that day (its products are over 2 days old, or it had no passes with a map):
# leave any maps it already has alone
if [ ${#day_passes[@]} -eq 0 ] && [ ${#night_passes[@]} -eq 0 ]; then
  log "Daily map: no kept passes for $day - its maps (if any) stay as they are" "INFO"
  find "$products" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null
  exit 0
fi

made=0
if [ ${#day_passes[@]} -gt 0 ]; then make_map day "MSA" "${day_layers[@]}" && made=1; else rm -f "$out/$day-day.jpg" "$out/thumb/$day-day.jpg"; fi
if [ ${#night_passes[@]} -gt 0 ]; then make_map night "MCIR" "${night_layers[@]}" && made=1; else rm -f "$out/$day-night.jpg" "$out/thumb/$day-night.jpg"; fi

if [ $made = 1 ]; then
  # what the page shows: the passes in each map, how each map was made and the area it covers
  printf '{"date":"%s","day":%s,"night":%s,"bounds":[%s,%s,%s,%s],"size":[%s,%s],"deg_per_px":0.025,"made":%s,' \
    "$day" "$(json_list "${day_passes[@]}")" "$(json_list "${night_passes[@]}")" \
    "$lon0" "$lat0" "$lon1" "$lat1" \
    "${map_size%x*}" "${map_size#*x}" "$(date +%s)" > "$out/$day.json"
  printf '"composites":{"day":{"name":"MSA","channels":[1],"wavelengths":"0.6 µm over a map"},"blend":true,' >> "$out/$day.json"
  printf '"night":{"name":"MCIR","channels":[4],"wavelengths":"3.8 µm over a map"}},' >> "$out/$day.json"
  printf '"projection":"%s","decoder":"%s"}\n' "${MAP_PROJECTION:-equal_earth}" "$($SATDUMP version 2>/dev/null | grep -om1 'SatDump v[0-9.]*' || echo SatDump)" >> "$out/$day.json"
fi

# the products are only needed while their day can still change
find "$products" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null

# the day's time-lapse over the animation area (enable_animation)
if [ "${ENABLE_ANIMATION:-false}" = "true" ]; then
  "$LRPT_HOME/scripts/animation.sh" "$day"
fi
