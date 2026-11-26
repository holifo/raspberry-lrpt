#!/bin/bash
#
# Live SSTV picture of an ISS pass: while receive_iss.sh records an SSTV pass on the ISS's own
# RTL-SDR, decode the audio received so far about every SSTV_LIVE_EVERY seconds and save the
# newest picture for the Passes page's ISS live panel ($IMAGE_OUTPUT/iss-live-sstv.jpg + .json).
#
#   live_sstv.sh RAW RATE START
#
#   RAW    the FM audio receive_iss.sh is writing (signed 16-bit mono)
#   RATE   its sample rate (22050 on the ISS's own dongle)
#   START  iss-live-info.json's "start", so the web panel shows only this pass's picture
#
# Each round decodes only the last SSTV_LIVE_WINDOW seconds (4 minutes: a PD180 picture with room
# either side), with sstv_decode.py's PD and Robot 36 decoders only, at the lowest priority, and
# keeps pictures with a few lines already, so one can be watched as it comes in. A round with no
# picture keeps the last one. It runs until iss-live-info.json is gone (receive_iss.sh also kills
# it when the recording ends), and skips itself on a Pi with fewer than 4 cores, or a round when
# memory is short, so the recording always comes first.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

RAW="$1"; RATE="$2"; START="$3"
EVERY="${SSTV_LIVE_EVERY:-30}"
FIRST="${SSTV_LIVE_FIRST:-45}"
WINDOW="${SSTV_LIVE_WINDOW:-240}"
INFO_FILE="${IMAGE_OUTPUT}/iss-live-info.json"
OUT_JPG="${IMAGE_OUTPUT}/iss-live-sstv.jpg"
OUT_JSON="${IMAGE_OUTPUT}/iss-live-sstv.json"

if [ "$(nproc)" -lt "${PREVIEW_MIN_CORES:-4}" ]; then
  log "Live SSTV picture skipped: it needs 4 CPU cores ($(nproc) here), the recording comes first" "INFO"
  exit 0
fi

TMP_DIR=$(mktemp -d "${LRPT_HOME}/tmp/live-sstv.XXXXXX") || exit 0
child=""
trap '[ -n "$child" ] && kill "$child" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT
trap 'exit 0' TERM INT

nap() { sleep "$1" & wait $!; }      # a TERM from receive_iss.sh ends it at once
nap "$FIRST"
last_size=0
while [ -f "$INFO_FILE" ]; do
  size=$(stat -c %s "$RAW" 2>/dev/null || echo 0)
  size=$(( size / 2 * 2 ))                           # whole samples
  avail=$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)
  # at least 10 s of new audio since the last round
  if [ "$size" -ge $(( RATE * 2 * 20 )) ] && [ "$size" -ge $(( last_size + RATE * 2 * 10 )) ] && [ "${avail:-0}" -ge 300 ]; then
    last_size=$size
    rm -rf "${TMP_DIR:?}"/*
    from=$(( size - WINDOW * RATE * 2 )); [ "$from" -lt 0 ] && from=0
    tail -c +$(( from + 1 )) "$RAW" | head -c $(( size - from )) > "$TMP_DIR/part.raw"
    nice -n 19 ionice -c 3 timeout 120 python3 "$IMAGE_PROC_DIR/sstv_decode.py" "$TMP_DIR/part.raw" "$TMP_DIR/live" \
      --rate "$RATE" --min-rows 0.03 --no-fallback > "$TMP_DIR/out.txt" 2>> "$LRPT_LOG" &
    child=$!
    wait "$child"; child=""
    # the newest picture (sstv_decode.py leaves out false runs made of stray sync pulses)
    line=$(grep '^{' "$TMP_DIR/out.txt" | tail -n 1)
    if [ -n "$line" ]; then
      read -r png mode rows complete < <(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["file"], d["mode"], d["rows"], "true" if d["complete"] else "false")' "$line")
      if [ -s "$png" ] && nice -n 19 convert "$png" -resize '480x>' -quality 85 "$TMP_DIR/live.jpg" 2>/dev/null; then
        mv -f "$TMP_DIR/live.jpg" "$OUT_JPG.tmp" && chmod 644 "$OUT_JPG.tmp" && mv -f "$OUT_JPG.tmp" "$OUT_JPG"
        printf '{"start":%s,"made":%s,"mode":"%s","rows":%s,"complete":%s}\n' "$START" "$(date +%s)" "$mode" "${rows:-0}" "$complete" \
          > "$OUT_JSON.tmp" && chmod 644 "$OUT_JSON.tmp" && mv -f "$OUT_JSON.tmp" "$OUT_JSON"
        log "Live SSTV picture: $mode, ${rows} lines" "DEBUG"
      fi
    fi
  fi
  nap "$EVERY"
done
