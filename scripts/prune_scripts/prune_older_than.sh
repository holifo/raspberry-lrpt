#!/bin/bash
#
# Purpose: Prunes (removes) all captures older than $PRUNE_OLDER_THAN days old, including
#          database records and associated images/files on disk.

# import common lib and settings
. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

#Generate date since epoch in seconds - days
let prunedate=$(date +%s)-$PRUNE_OLDER_THAN*24*60*60

log "Pruning captures..." "INFO"
for img_path in $(sqlite3 ${DB_FILE} "select file_path from decoded_passes where pass_start < $prunedate;"); do
  log "  ${img_path} file pruned" "INFO"
  sqlite3 "${DB_FILE}" "delete from decoded_passes where file_path = \"$img_path\";"
  log "  Database entry pruned" "INFO"
done
find /srv/images /srv/images/thumb -type f \( -name '*.jpg' -o -name '*.png' \) -not -path '*/images/station/*' -mtime +$PRUNE_OLDER_THAN -delete
find "$IMAGE_OUTPUT/daily" -maxdepth 1 -type f -name '*.json' -mtime +$PRUNE_OLDER_THAN -delete 2>/dev/null   # daily maps (their images go above)
find "$IMAGE_OUTPUT/daily/timelapse" -maxdepth 1 -type f -mtime +$PRUNE_OLDER_THAN -delete 2>/dev/null       # daily time-lapses
