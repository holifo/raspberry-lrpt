#!/usr/bin/env bash
#
# Purpose: Draw the station label (config/annotation/annotation.yml) with example pass details,
#          to check how it looks before a real pass.
#
# Inputs:
#    1. Output file to store the image to
#
# Example:
#   ./produce_annotation_image.sh /tmp/output.png

# import common lib and settings
. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

# make sure an output file is specified
if [ -z "$1" ]; then
  log "Usage: ./produce_annotation_image.sh <output_png_file>" "ERROR"
  exit 1
fi

settings_file="${LRPT_HOME}/config/.settings.merged.yml"
[ -f "$settings_file" ] || settings_file="${LRPT_HOME}/config/settings.yml"

if python3 "$SCRIPTS_DIR/image_processors/annotation_panel.py" "$settings_file" \
     "${LRPT_HOME}/config/annotation/annotation.yml" "$1" \
     "sat_name=METEOR-M2 3" "capture_start=19/02/2026 19:42" "enhancement=MCIR_corrected" \
     "sat_max_elevation=42" "sun_elevation=-12" "pass_direction=Northbound" "pass_side=E" \
     "pass_side_long=East" "gain=40.2"; then
  log "Label drawn - see $1" "INFO"
else
  log "Could not draw the label - see the error above" "ERROR"
  exit 1
fi
