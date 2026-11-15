#!/bin/bash
#
# Applies the database schema updates that are missing. Each update adds a column (or, for
# 00, creates the tables); it is applied only when that column is not there yet. Only the
# updates actually applied are logged, plus one summary line.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

SQL_CMD=/usr/bin/sqlite3
DB="$LRPT_HOME/db/panel.db"

# script                              table           column that shows it is applied
MIGRATIONS=(
  "00_seed_schema.sql                 decoded_passes  id"
  "01_add_spectrogram_bool.sql        decoded_passes  has_spectrogram"
  "02_add_pristine_bool.sql           decoded_passes  has_pristine"
  "03_add_pass_azimuth_direction.sql  predict_passes  pass_start_azimuth"
  "04_add_capture_gain.sql            decoded_passes  gain"
  "05_add_pass_azimuth_at_max.sql     predict_passes  azimuth_at_max"
  "06_add_polar_az_el_bool.sql        decoded_passes  has_polar_az_el"
  "07_add_polar_direction_bool.sql    decoded_passes  has_polar_direction"
  "08_add_histogram_bool.sql          decoded_passes  has_histogram"
  "09_add_at_job_id.sql               predict_passes  at_job_id"
)

applied=0
for m in "${MIGRATIONS[@]}"; do
  read -r script table column <<< "$m"
  if ! $SQL_CMD "$DB" ".schema $table" | grep -qw "$column"; then
    log "Database: applying ${script}" "INFO"
    $SQL_CMD "$DB" < "$LRPT_HOME/db_migrations/$script" || { log "Database: ${script} failed" "ERROR"; exit 1; }
    applied=$((applied + 1))
  fi
done

if [ $applied -eq 0 ]; then
  log "Database schema is up to date" "INFO"
else
  log "Database schema updated (${applied} change(s))" "INFO"
fi
