#!/bin/bash
#
# Purpose: A time-lapse of one (local) day's passes over one area (Greece by default), shown with
#          that day's maps on the Daily map page. Every pass is projected onto the same map of the
#          area, so the frames line up. All frames use the 3.9 µm infrared image (channel 4), which
#          looks the same by day and by night, so the loop doesn't flicker between visible and
#          infrared.
#
# Input:   the passes' SatDump products kept for the daily map
#          ($METEOR_AUDIO_OUTPUT/products/<pass>, kept 2 days; needs daily_map: true), and the
#          frames already made from them ($IMAGE_OUTPUT/animation/frames, kept 7 days), so a day
#          can still be rebuilt after its products are gone
# Output:  $IMAGE_OUTPUT/daily/timelapse/<YYYY-MM-DD>.webm and .mp4, the last frame as
#          <YYYY-MM-DD>.jpg, and <YYYY-MM-DD>.json (area, passes, when it was made) for the web
#          panel. A day with no frames is left as it is.
#
# Settings: enable_animation, animation_area ("W E S N" in degrees)
#
# Usage:   ./animation.sh [YYYY-MM-DD]   (default: today; run by daily_map.sh after each pass)
#          ./animation.sh --all         every day that still has products or frames
#          ./animation.sh --redo [...]  project every frame again (after changing the area)

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

redo=false
[ "$1" = "--redo" ] && { redo=true; shift; }

products="$METEOR_AUDIO_OUTPUT/products"
frames="$IMAGE_OUTPUT/animation/frames"
out="$IMAGE_OUTPUT/daily/timelapse"
mkdir -p "$frames" "$out" "$LRPT_HOME/tmp"

# pass_day BASE: the (local) day of a pass, from the UTC time in its name
pass_day() {
  [[ "$1" =~ ([0-9]{8})-([0-9]{6})$ ]] || return 1
  date -d "${BASH_REMATCH[1]:0:4}-${BASH_REMATCH[1]:4:2}-${BASH_REMATCH[1]:6:2} ${BASH_REMATCH[2]:0:2}:${BASH_REMATCH[2]:2:2}:${BASH_REMATCH[2]:4:2} UTC" +%F
}

# --all: every day that still has products or frames, one after another
if [ "$1" = "--all" ]; then
  $redo && rm -f "$frames/.area"
  for d in $( { ls -1 "$products" 2>/dev/null; ls -1 "$frames" 2>/dev/null | sed -E 's/\.(jpg|skip)$//'; } |
             grep '^METEOR-M2-' | while read -r b; do pass_day "$b"; done | sort -u); do
    "$0" "$d"
  done
  exit 0
fi

day="${1:-$(date +%F)}"
date -d "$day" >/dev/null 2>&1 || { log "Time-lapse: not a date: $day" "ERROR"; exit 1; }

# one run at a time
exec 8>"$LRPT_HOME/tmp/animation.lock"
flock 8

# the rolling 48-hour animation of v1.11 is replaced by one time-lapse per day
if [ -n "$ANIMATION_OUTPUT" ]; then
  rm -f "${ANIMATION_OUTPUT%.webm}".webm "${ANIMATION_OUTPUT%.webm}".mp4 \
        "$(dirname "$ANIMATION_OUTPUT")"/animation.jpg "$(dirname "$ANIMATION_OUTPUT")"/animation.json 2>/dev/null
fi

# the area: west east south north, 0.01° a pixel (about 1 km, the satellite's own resolution)
read -r west east south north <<< "${ANIMATION_AREA:-19 30 34 42}"
# the composite and the channel it needs (can be overridden from the environment, for tests)
composite=${ANIMATION_COMPOSITE:-Shortwave IR (Uncalibrated)}
need_channel=${ANIMATION_CHANNEL:-4}
scale=0.01
width=$(awk -v a="$west" -v b="$east" -v s="$scale" 'BEGIN { w = int((b - a) / s); print w - w % 2 }')
height=$(awk -v a="$south" -v b="$north" -v s="$scale" 'BEGIN { h = int((b - a) / s); print h - h % 2 }')
area_key="$west $east $south $north ${MAP_PROJECTION:-equal_earth}"

# frames made for another area are no use
if [ "$(cat "$frames/.area" 2>/dev/null)" != "$area_key" ] || $redo; then
  rm -f "$frames"/*.jpg "$frames"/*.skip
  echo "$area_key" > "$frames/.area"
fi

capitals=()
[ "${MAP_CAPITALS:-true}" = "true" ] && capitals=(--draw_cities_overlay --cities_type 0 --cities_scale_rank 3 --cities_size 20)

# project_one BASE: the pass onto the area, labelled with its time and satellite. A pass that
# covers less than a fifth of the area gets a .skip marker instead of a frame.
project_one() {
  local base=$1 dir="$products/$1" work cover label sat when
  work=$(mktemp -d "$LRPT_HOME/tmp/anim-$base.XXXXXX")
  $SATDUMP project -layer --type product --file "$dir/product.cbor" --composite "$composite" \
    -target --type equirec --offset_x "$west" --offset_y "$north" \
            --scalar_x "$scale" --scalar_y "-$scale" --width "$width" --height "$height" \
            --draw_map_overlay --draw_qth_overlay "${capitals[@]}" --file "$work/f.png" > "$work/log" 2>&1
  if [ ! -s "$work/f.png" ]; then
    log "Time-lapse: SatDump made no frame for $base" "WARN"
    touch "$frames/$base.skip"; rm -rf "$work"; return
  fi
  # Equal Earth (map_projection), before the labels so they stay straight
  reproject "$work/f.png" "$work/f.png" "$west" "$north" "$east" "$south" --keep-alpha >/dev/null
  # how much of the area the pass covers (its opaque part)
  cover=$($CONVERT "$work/f.png" -alpha extract -format '%[fx:mean]' info: 2>/dev/null || echo 1)
  if awk -v c="$cover" 'BEGIN { exit !(c < 0.2) }'; then
    log "Time-lapse: $base covers only $(awk -v c="$cover" 'BEGIN { printf "%d", c * 100 }')% of the area - left out" "INFO"
    touch "$frames/$base.skip"; rm -rf "$work"; return
  fi
  [[ "$base" =~ (METEOR-M2-[0-9])-([0-9]{8})-([0-9]{6})$ ]]
  sat=${BASH_REMATCH[1]/-M2-/-M2 }
  when=$(date -d "${BASH_REMATCH[2]:0:4}-${BASH_REMATCH[2]:4:2}-${BASH_REMATCH[2]:6:2} ${BASH_REMATCH[3]:0:2}:${BASH_REMATCH[3]:2:2}:${BASH_REMATCH[3]:4:2} UTC" '+%d/%m/%Y %H:%M')
  label="$when  ·  $sat"
  $CONVERT -background '#0b1220' "$work/f.png" -flatten \
    -gravity SouthWest -fill white -undercolor '#0b1220cc' -pointsize 26 -annotate +12+12 " $label " \
    -gravity NorthEast -fill '#9fb3c8' -undercolor '#0b1220cc' -pointsize 18 -annotate +12+12 " ${STATION_TITLE:-Raspberry-LRPT} · 3.9 µm IR " \
    -quality 90 "$frames/$base.jpg" >> "$LRPT_LOG" 2>&1
  rm -rf "$work"
}

# the day's passes, oldest first: those with a product (a frame can be made) and those that
# already have a frame (their product may be gone)
bases=()
for base in $( { ls -1 "$products" 2>/dev/null; ls -1 "$frames" 2>/dev/null | sed -E 's/\.(jpg|skip)$//'; } |
               grep '^METEOR-M2-' | sort -u | sort -t- -k4,5); do
  [ "$(pass_day "$base")" = "$day" ] || continue
  if [ -f "$products/$base/product.cbor" ] && [ -f "$products/$base/MSU-MR-$need_channel.png" ]; then
    bases+=("$base")
  elif [ -f "$frames/$base.jpg" ]; then
    bases+=("$base")
  fi
done

# project the passes that have no frame yet (or were re-processed since), one per core
todo=0
for base in "${bases[@]}"; do
  [ -f "$products/$base/product.cbor" ] || continue
  if [ -f "$frames/$base.jpg" ] && [ "$frames/$base.jpg" -nt "$products/$base/product.cbor" ]; then continue; fi
  if [ -f "$frames/$base.skip" ] && [ "$frames/$base.skip" -nt "$products/$base/product.cbor" ]; then continue; fi
  rm -f "$frames/$base.jpg" "$frames/$base.skip"
  project_one "$base" &
  throttle
  todo=$((todo + 1))
done
wait

# frames are kept a week, so a day can be rebuilt after its products are gone
find "$frames" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.skip' \) -mtime +7 -delete 2>/dev/null

list=()
for base in "${bases[@]}"; do [ -f "$frames/$base.jpg" ] && list+=("$base"); done
if [ ${#list[@]} -eq 0 ]; then
  log "Time-lapse: no pass of $day covers the area ($area_key) - nothing to show" "INFO"
  exit 0
fi

# the video: 2 frames a second, the newest frame held for 2 seconds; VP9 (WebM) and H.264 (MP4,
# for phones that don't play WebM)
work=$(mktemp -d "$LRPT_HOME/tmp/anim-video.XXXXXX")
k=0
for base in "${list[@]}" "${list[-1]}" "${list[-1]}" "${list[-1]}"; do
  ln -s "$frames/$base.jpg" "$(printf '%s/%04d.jpg' "$work" "$k")"; k=$((k + 1))
done
ffmpeg -hide_banner -loglevel error -y -framerate 2 -i "$work/%04d.jpg" -an \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 0 -crf 34 -pix_fmt yuv420p "$work/a.webm" >> "$LRPT_LOG" 2>&1
ffmpeg -hide_banner -loglevel error -y -framerate 2 -i "$work/%04d.jpg" -an \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -movflags +faststart -r 2 "$work/a.mp4" >> "$LRPT_LOG" 2>&1
[ -s "$work/a.webm" ] && mv -f "$work/a.webm" "$out/$day.webm"
[ -s "$work/a.mp4" ] && mv -f "$work/a.mp4" "$out/$day.mp4"
$CONVERT "$frames/${list[-1]}.jpg" -resize '640x640>' -quality 85 "$out/$day.jpg" 2>/dev/null ||
  cp -f "$frames/${list[-1]}.jpg" "$out/$day.jpg"

# what the page shows: the area, the passes in the loop and when it was made
{
  size=$($CONVERT "$frames/${list[-1]}.jpg" -format '%w %h' info: 2>/dev/null || echo "$width $height")
  printf '{"date":"%s","bounds":[%s,%s,%s,%s],"size":[%s,%s],"made":%s,"projection":"%s","composite":"3.9 µm Shortwave IR","passes":[' \
    "$day" "$west" "$north" "$east" "$south" ${size% *} ${size#* } "$(date +%s)" "${MAP_PROJECTION:-equal_earth}"
  first=1
  for base in "${list[@]}"; do [ $first = 1 ] || printf ','; printf '"%s"' "$base"; first=0; done
  printf ']}\n'
} > "$out/$day.json"
rm -rf "$work"
log "Time-lapse $day: ${#list[@]} passes over $area_key ($todo newly projected) -> $out/$day.webm / .mp4" "INFO"
