#!/bin/bash
#
# Live preview of a Meteor pass (live_preview): while satdump live records, decode the frames it
# has written so far about every PREVIEW_EVERY seconds and save a small picture for the web panel's
# live decode panel ($IMAGE_OUTPUT/live-preview.jpg + live-preview.json).
#
#   live_preview.sh CADU START DAYLIGHT FLIP
#
#   CADU     the frames file satdump live is writing (meteor_m2-x_lrpt.cadu in its work folder)
#   START    the pass's live.json "start", so the web panel shows only this pass's picture
#   DAYLIGHT 1 = channel 2 (visible), else an IR channel
#   FLIP     true = turn it 180° (northbound pass, as receive_meteor.sh does with flip_meteor_img)
#
# SatDump writes the raw channel pictures (MSU-MR-N.png) before its slow products step, so each
# decode is stopped as soon as it reaches that step: a few seconds at the lowest priority. It runs
# until $IMAGE_OUTPUT/live.json is gone (receive_meteor.sh also kills it when SatDump ends), and
# skips itself on a Pi with fewer than 4 cores, or a round when memory is short, so the live
# decode always comes first.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

CADU="$1"; START="$2"; DAYLIGHT="$3"; FLIP="$4"
PREVIEW_EVERY="${PREVIEW_EVERY:-45}"
PREVIEW_FIRST="${PREVIEW_FIRST:-60}"
LIVE_FILE="${IMAGE_OUTPUT}/live.json"
OUT_JPG="${IMAGE_OUTPUT}/live-preview.jpg"
OUT_JSON="${IMAGE_OUTPUT}/live-preview.json"

if [ "$(nproc)" -lt "${PREVIEW_MIN_CORES:-4}" ]; then
  log "Live preview skipped: it needs 4 CPU cores ($(nproc) here), the live decode comes first" "INFO"
  exit 0
fi

TMP_DIR=$(mktemp -d "${LRPT_HOME}/tmp/live-preview.XXXXXX") || exit 0
child=""
trap '[ -n "$child" ] && kill "$child" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT
trap 'exit 0' TERM INT

# MSU-MR channels in order of preference: visible by day, infrared at night
if [ "$DAYLIGHT" == "1" ]; then channels="2 1 3"; else channels="4 5 3 6"; fi

nap() { sleep "$1" & wait $!; }      # a TERM from receive_meteor.sh ends it at once
nap "$PREVIEW_FIRST"
last_size=0
while [ -f "$LIVE_FILE" ]; do
  size=$(stat -c %s "$CADU" 2>/dev/null || echo 0)
  avail=$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)
  if [ "$size" -ge 262144 ] && [ "$size" -gt "$last_size" ] && [ "${avail:-0}" -ge 400 ]; then
    last_size=$size
    rm -rf "$TMP_DIR"/*
    head -c $(( size / 1024 * 1024 )) "$CADU" > "$TMP_DIR/part.cadu"      # whole 1024-byte frames
    nice -n 19 ionice -c 3 $SATDUMP meteor_m2-x_lrpt cadu "$TMP_DIR/part.cadu" "$TMP_DIR/out" \
      > "$TMP_DIR/satdump.log" 2>&1 &
    child=$!
    for _ in $(seq 600); do                  # up to 2 minutes, then give up on this round
      kill -0 "$child" 2>/dev/null || break
      grep -q "Products processing" "$TMP_DIR/satdump.log" && break
      sleep 0.2
    done
    kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child=""

    pic=""; ch=""
    for c in $channels; do
      [ -s "$TMP_DIR/out/MSU-MR/MSU-MR-$c.png" ] && { pic="$TMP_DIR/out/MSU-MR/MSU-MR-$c.png"; ch=$c; break; }
    done
    if [ -n "$pic" ]; then
      lines=$(sed 's/\x1b\[[0-9;]*m//g' "$TMP_DIR/satdump.log" | sed -n "s/.*MSU-MR Channel $ch Lines *: *\([0-9]*\).*/\1/p" | tail -1)
      rot=""; [ "$FLIP" == "true" ] && rot="-rotate 180"
      if nice -n 19 convert "$pic" -resize '480x>' -normalize $rot -quality 82 "$TMP_DIR/preview.jpg" 2>/dev/null; then
        mv -f "$TMP_DIR/preview.jpg" "$OUT_JPG.tmp" && chmod 644 "$OUT_JPG.tmp" && mv -f "$OUT_JPG.tmp" "$OUT_JPG"
        printf '{"start":%s,"made":%s,"channel":%s,"lines":%s}\n' "$START" "$(date +%s)" "$ch" "${lines:-0}" > "$OUT_JSON.tmp" &&
          chmod 644 "$OUT_JSON.tmp" && mv -f "$OUT_JSON.tmp" "$OUT_JSON"
        log "Live preview: channel $ch, ${lines:-?} lines" "DEBUG"
      fi
    fi
  fi
  nap "$PREVIEW_EVERY"
done
