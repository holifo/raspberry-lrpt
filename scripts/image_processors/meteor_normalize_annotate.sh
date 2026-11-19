#!/bin/bash
#
# Purpose: Add annotation text inline with image for a METEOR capture and writes file
#          to specified output image file.
#
# Input parameters:
#   1. Input .jpg file
#   2. Output .jpg file
#   3. Image quality percent (whole number)
#
# Example:
#   ./meteor_normalize_annotate.sh /path/to/inputfile.jpg /path/to/outputfile.jpg

# import common lib and settings
. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

# input params
INPUT_JPG=$1
OUTPUT_JPG=$2
QUALITY=$3


# provide a long-form pass side
pass_side_long="West"
if [ "${PASS_SIDE}" == "E" ]; then
  pass_side_long="East"
fi

# determine if auto-gain is set - handles "0" and "0.0" floats
gain=$GAIN
if [ $(echo "$GAIN==0"|bc) -eq 1 ]; then
  gain='Automatic'
fi

# the install's merged settings (settings.yml + this station's settings.local.yml)
settings_file="${LRPT_HOME}/config/.settings.merged.yml"
[ -f "$settings_file" ] || settings_file="${LRPT_HOME}/config/settings.yml"
layout_file="${LRPT_HOME}/config/annotation/annotation.yml"
pass_values=("sat_name=$SAT_NAME" "capture_start=$START_DATE"
             "sat_max_elevation=$SAT_MAX_ELEVATION" "sun_elevation=$SUN_ELEV"
             "pass_direction=$PASS_DIRECTION" "pass_side=$PASS_SIDE" "pass_side_long=$pass_side_long"
             "gain=$gain")

# a private work folder, so several images can be annotated at once
tmp_dir=$(mktemp -d "${LRPT_HOME}/tmp/annotation.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
annotation="${tmp_dir}/annotation.png"

# the panel is the same for every image of a pass: draw it once and keep it, keyed by the
# settings, pass details and layout (and logo) it is made from
cache_dir="${LRPT_HOME}/tmp/annotation-cache"
mkdir -p "$cache_dir"
find "$cache_dir" -type f -mmin +720 -delete 2>/dev/null
panel_key=$( { cat "$settings_file"; printf '%s\n' "${pass_values[@]}"; cat "${LRPT_HOME}/config/annotation/"* 2>/dev/null; } \
             | md5sum | cut -c1-16)
panel="${cache_dir}/${panel_key}.png"

if [ ! -s "$panel" ]; then
  # the panel: drawn with Pillow (annotation.yml), light grey and 70% transparent with a dark
  # border and rounded corners; text and logo opaque
  if ! python3 "$SCRIPTS_DIR/image_processors/annotation_panel.py" "$settings_file" "$layout_file" \
       "${annotation}" "${pass_values[@]}"; then
    log "Could not draw the annotation for ${INPUT_JPG}; the image is kept without it" "WARN"
    [ "${INPUT_JPG}" == "${OUTPUT_JPG}" ] || cp "${INPUT_JPG}" "${OUTPUT_JPG}"
    exit 0
  fi
  # keep it for the pass's other images (mv is atomic, so parallel runs never see half a file)
  # (no "-colorspace RGB" anywhere in this script: on ImageMagick 6.9 it converts to linear RGB and
  #  saves it that way, which makes the whole capture about 3x darker)
  cp "${annotation}" "${panel}.$$" && mv -f "${panel}.$$" "${panel}"
else
  cp "$panel" "${annotation}"
fi

# resize the annotation, keeping aspect ratio: to ANNOTATION_WIDTH_PERCENT of the
# capture image's width when set, otherwise as drawn (twice the layout's base size)
if [ -n "${ANNOTATION_WIDTH_PERCENT}" ] && [ "${ANNOTATION_WIDTH_PERCENT%.*}" -gt 0 ] 2>/dev/null; then
  capture_w=$($IDENTIFY -format "%w" "${INPUT_JPG}")
  new_img_w=$(( capture_w * ${ANNOTATION_WIDTH_PERCENT%.*} / 100 ))
  $CONVERT "${annotation}" -resize "${new_img_w}x" "${annotation}"
fi

# extend the image if the user specified and didn't use
# one of [West|Center|East] for the annotation location
annotation_location=$(echo $IMAGE_ANNOTATION_LOCATION | tr '[:upper:]' '[:lower:]')
extend_annotation=0
if [ "${EXTEND_FOR_ANNOTATION}" == "true" ]; then
  if [[ "${annotation_location}" =~ ^(west|center|east)$ ]]; then
    log "You specified extending the annotation, but your annotation location $annotation_location does not support it" "WARN"
  else
    extend_annotation=1
  fi
fi

# generate the final image with annotation
if [ $extend_annotation -eq 1 ]; then
  # calculate expansion height needed to fit annotation
  annotation_h=$($IDENTIFY -format "%h" "${annotation}")
  img_expand_px=$(($annotation_h + 20))
  out_file=$(basename $OUTPUT_JPG)
  tmp_out="${LRPT_HOME}/tmp/${out_file%%.*}-tmp.jpg"

  # create pixels north or south depending on annotation location
  gravity_var="South"
  if [[ "${annotation_location}" =~ ^(northwest|north|northeast)$ ]]; then
    gravity_var="North"
  fi

  $CONVERT -interlace Line -quality 100 \
           -format jpg "${INPUT_JPG}" \
           -gravity "${gravity_var}" \
           -background black \
           -splice "0x${img_expand_px}" "${tmp_out}"

  # generate final image with annotation
  $CONVERT -interlace Line -format jpg "${tmp_out}" "${annotation}" \
           -gravity $IMAGE_ANNOTATION_LOCATION \
           -geometry +0+10 \
           -composite -type TrueColor "${OUTPUT_JPG}"

  # clean up
  rm "${tmp_out}"
else
  $CONVERT -interlace Line -format jpg "${INPUT_JPG}" "${annotation}" \
           -gravity $IMAGE_ANNOTATION_LOCATION \
           -geometry +10+10 \
           -composite -type TrueColor "${OUTPUT_JPG}"
fi

# (the work folder is removed on exit)
