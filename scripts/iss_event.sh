#!/bin/bash
#
# An ARISS SSTV event in one command: the ISS records SSTV pictures between two dates, then goes
# back to APRS (or to nothing, with iss_aprs: false) by itself when the event is over.
#
#   scripts/iss_event.sh                              what the ISS records now and next
#   scripts/iss_event.sh FROM TO [2m|70cm|MHz]        an SSTV event, e.g. 2026-12-01 2026-12-07 70cm
#   scripts/iss_event.sh --off                        no event (APRS on every ISS pass)
#
# 2m = 145.800 MHz, 70cm = 437.550 MHz (ARISS's 2026 events). Without a band the SSTV frequency
# setting stays as it is. The SSTV mode needs no setting: every recording is decoded as PD
# (PD 90/120/180) and as Robot 36. The ISS is switched on if it was off. The changes are saved in
# config/settings.local.yml (like Admin > Settings) and the passes are scheduled again.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

status() {
  local from to today
  read -r from to <<< "${ISS_SSTV_DATES}"
  today=$(date +%F)
  echo "ISS: $([ "$ISS_SSTV" == "true" ] && echo on || echo off)"
  if [ -n "$from" ]; then
    if [[ "$today" > "$to" ]]; then state="over"
    elif [[ "$today" < "$from" ]]; then state="coming"
    else state="now"; fi
    echo "SSTV event: $from to $to ($state), ${ISS_SSTV_FREQ} MHz, PD and Robot 36 decoded"
  else
    echo "SSTV event: none set"
  fi
  if [ "$ISS_APRS" == "true" ]; then
    echo "APRS: ${ISS_APRS_FREQ} MHz on every ISS pass outside an SSTV event"
  elif [ -z "$from" ]; then
    echo "APRS: off, so every ISS pass records SSTV on ${ISS_SSTV_FREQ} MHz"
  else
    echo "APRS: off, so ISS passes outside the event are not recorded"
  fi
  echo "Check what the ISS sends now: https://www.ariss.org/current-status-of-iss-stations.html"
}

apply() {
  local result
  if pgrep -f "$METEOR_RUNNING" > /dev/null || pgrep -f "$ISS_RUNNING" > /dev/null; then
    echo "A pass is being recorded - try again when it has finished."
    exit 2
  fi
  result=$(python3 "$LRPT_HOME/scripts/tools/settings_form.py" apply <<< "$1")
  if ! python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["ok"] else 1)' <<< "$result" 2>/dev/null; then
    echo "Not saved: $result"
    exit 1
  fi
  log "ISS SSTV event changed: $1" "INFO" > /dev/null
  . "$HOME/.raspberry-lrpt.conf"         # the values just written
  status
  echo "Scheduling the passes again..."
  flock "$LRPT_HOME/tmp/settings-schedule.lock" "$LRPT_HOME/scripts/schedule.sh" -t -x >> "$LRPT_LOG" 2>&1 &&
    echo "Done." || echo "The scheduler reported a problem - see $LRPT_LOG"
}

case "${1:-}" in
  "")
    status ;;
  --off|off)
    apply '{"iss_sstv_dates": ""}' ;;
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
    from="$1"; to="${2:-}"
    if ! date -d "$from" +%F >/dev/null 2>&1 || ! date -d "$to" +%F >/dev/null 2>&1 || [[ "$to" < "$from" ]]; then
      echo "Give two dates, the first not after the second: $0 2026-12-01 2026-12-07 [2m|70cm]"
      exit 1
    fi
    case "${3:-}" in
      "")   freq="" ;;
      2m)   freq="145.800" ;;
      70cm) freq="437.550" ;;
      *)    freq="$3" ;;
    esac
    json=$(printf '{"iss_sstv": "true", "iss_sstv_dates": "%s %s"%s}' "$(date -d "$from" +%F)" "$(date -d "$to" +%F)" \
      "${freq:+, \"iss_sstv_frequency\": \"$freq\"}")
    apply "$json" ;;
  *)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
