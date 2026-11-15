#!/bin/bash
#
# Posts captures that are already on the site to Discord, the same way new passes are posted
# (settings: discord_webhook, discord_site_url, discord_images, discord_sky_track).
#
#   discord_post.sh -l                 list the newest 20 captures with their numbers (ids)
#   discord_post.sh ID [ID ...]        post these captures
#   discord_post.sh --last N           post the newest N captures
#   discord_post.sh --day YYYY-MM-DD   post every capture of that (local) day
#   discord_post.sh --today            post every capture of today
#   -y                                 don't ask before posting
#
# Captures are posted oldest first, one at a time. A capture whose images were already deleted
# (older than delete_older_than_n days) is skipped.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

usage() { sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

if [ -z "${DISCORD_WEBHOOK}" ]; then
  echo "discord_webhook is not set - run ./install_and_upgrade.sh and answer the Discord question"
  exit 1
fi

COLS="d.id, d.pass_start, d.file_path, d.daylight_pass, COALESCE(p.sat_name, ''),
      COALESCE(p.max_elev, 0), COALESCE(p.direction, ''), COALESCE(p.pass_end - p.pass_start, 0)"
FROM="decoded_passes d LEFT JOIN predict_passes p ON p.pass_start = d.pass_start"

yes=0 where="" order="ASC" limit=""
ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    -y|--yes)  yes=1 ;;
    -l|--list)
      printf '%6s  %-16s  %-12s  %5s  %s\n' "Number" "Pass (local)" "Satellite" "Elev" "Day/night"
      $SQLITE3 -separator '|' "$DB_FILE" "SELECT $COLS FROM $FROM ORDER BY d.pass_start DESC LIMIT 20;" |
        while IFS='|' read -r id start base day sat elev dir secs; do
          printf '%6s  %-16s  %-12s  %4s°  %s\n' "$id" "$(date -d "@$start" '+%d/%m/%Y %H:%M')" \
                 "${sat:-?}" "$elev" "$([ "$day" == 1 ] && echo day || echo night)"
        done
      exit 0 ;;
    --last)
      [[ "$2" =~ ^[0-9]+$ ]] || usage 1
      where="1"; order="DESC"; limit="LIMIT $2"; shift ;;
    --today|--day)
      if [ "$1" == "--today" ]; then d=$(date '+%Y-%m-%d'); else d=$2; shift; fi
      from=$(date -d "$d 00:00" +%s 2>/dev/null) || { echo "Not a date: $d"; exit 1; }
      to=$(date -d "$d 00:00 + 1 day" +%s)
      where="d.pass_start >= $from AND d.pass_start < $to" ;;
    *)
      [[ "$1" =~ ^[0-9]+$ ]] || usage 1
      ids+=("$1") ;;
  esac
  shift
done

if [ ${#ids[@]} -gt 0 ]; then
  where="d.id IN ($(IFS=,; echo "${ids[*]}"))"
fi
[ -n "$where" ] || usage 1

mapfile -t rows < <($SQLITE3 -separator '|' "$DB_FILE" "SELECT $COLS FROM $FROM WHERE $where ORDER BY d.pass_start $order $limit;")
[ "$order" == "DESC" ] && mapfile -t rows < <(printf '%s\n' "${rows[@]}" | tac)
if [ ${#rows[@]} -eq 0 ] || [ -z "${rows[0]}" ]; then
  echo "No captures found"
  exit 1
fi

echo "To post to Discord:"
for row in "${rows[@]}"; do
  IFS='|' read -r id start base day sat elev dir secs <<< "$row"
  echo "  #$id  $(date -d "@$start" '+%d/%m/%Y %H:%M')  ${sat:-?}  ${elev}°"
done
if [ $yes -eq 0 ]; then
  read -r -p "Post ${#rows[@]} capture(s)? [y/N] " answer < /dev/tty
  [[ "$answer" =~ ^[Yy] ]] || { echo "Nothing posted"; exit 0; }
fi

posted=0 skipped=0 failed=0
for row in "${rows[@]}"; do
  IFS='|' read -r id start base day sat elev dir secs <<< "$row"
  [ -n "$sat" ] || sat=$(echo "$base" | sed -E 's/^(METEOR-M2-?[0-9]).*/\1/; s/M2-/M2 /')
  [ "$secs" -gt 0 ] 2>/dev/null || secs=0
  discord_pass "$base" "$day" "$sat" "$start" "$elev" "${dir:-unknown}" "$secs" "$id" --wait > /dev/null
  case $? in
    0) posted=$((posted + 1)); echo "  #$id posted" ;;
    1) if ls "${IMAGE_OUTPUT}/${base}"-* > /dev/null 2>&1; then
         failed=$((failed + 1)); echo "  #$id failed (see the log)"
       else
         skipped=$((skipped + 1)); echo "  #$id skipped: its images are gone"
       fi ;;
  esac
  sleep 2    # stay well inside Discord's rate limit
done
echo "Posted $posted, skipped $skipped, failed $failed"
[ $failed -eq 0 ]
