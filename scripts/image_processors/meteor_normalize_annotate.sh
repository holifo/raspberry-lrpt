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

# get the base config and append vars as needed
# the install's merged settings (settings.yml + this station's settings.local.yml)
settings_file="${LRPT_HOME}/config/.settings.merged.yml"
[ -f "$settings_file" ] || settings_file="${LRPT_HOME}/config/settings.yml"
yml_config=$(cat "$settings_file")
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/sat_name: '$SAT_NAME'\n.../")                   # sat_name
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/capture_start: '$START_DATE'\n.../")            # capture_start
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/enhancement: '$ENHANCEMENT'\n.../")             # enhancement
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/sat_max_elevation: '$SAT_MAX_ELEVATION'\n.../") # sat_max_elevation
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/sun_elevation: '$SUN_ELEV'\n.../")              # sun_elevation
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/pass_direction: $PASS_DIRECTION\n.../")         # pass_direction
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/pass_side: $PASS_SIDE\n.../")                   # pass_side
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/pass_side_long: $pass_side_long\n.../")         # pass_side_long
yml_config=$(echo "${yml_config}" | sed -e "s/\.\.\.$/gain: $gain\n.../")                             # gain

# vars for image manipulation: a private work folder, so several images can be annotated at once
tmp_dir=$(mktemp -d "${LRPT_HOME}/tmp/annotation.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
rendered_file="${tmp_dir}/index.html"
annotation="${tmp_dir}/annotation.png"

# the panel is the same for every image of a pass: render it once and keep it, keyed by the
# settings, pass details and template it is made from
cache_dir="${LRPT_HOME}/tmp/annotation-cache"
mkdir -p "$cache_dir"
find "$cache_dir" -type f -mmin +720 -delete 2>/dev/null
panel_key=$( { echo "${yml_config}"; cat "${LRPT_HOME}/config/annotation/"*; } | md5sum | cut -c1-16)
panel="${cache_dir}/${panel_key}.png"

if [ ! -s "$panel" ]; then
# generate annotation html and copy any assets
$SCRIPTS_DIR/tools/jinja2_to_file.py "${LRPT_HOME}/config/annotation/annotation.html.j2" "${yml_config}" "${rendered_file}"
find $LRPT_HOME/config/annotation/* -type f -not -name "*.j2" -exec cp {} "${tmp_dir}/" \;

# generate annotation png and crop to content
# wkhtmltoimage (Qt) wants a private runtime folder: in an SSH session /run/user/<uid> can be
# 0770, which makes Qt print "QStandardPaths: wrong permissions on runtime directory"; --quiet
# drops its "Loading page (1/2)" progress lines
qt_runtime="${XDG_RUNTIME_DIR_QT:-/tmp/runtime-$(id -un)}"
mkdir -p -m 700 "$qt_runtime" && chmod 700 "$qt_runtime"
XDG_RUNTIME_DIR="$qt_runtime" $WKHTMLTOIMG --quiet --enable-local-file-access --format png --quality 100 "file://${rendered_file}" "${annotation}"
# (no "-colorspace RGB" anywhere in this script: on ImageMagick 6.9 it converts to linear RGB and
#  saves it that way, which makes the whole capture about 3x darker)
$CONVERT -format png "${annotation}" -background none -flatten -trim +repage "${annotation}"

# rounded corners and a 70% transparent panel, done here because Debian's wkhtmltoimage
# (unpatched Qt) ignores --transparent. The template paints the panel #cacaca on a white
# page: pixels close to the panel colour get alpha 0.3, darker text/logo/border pixels
# stay opaque, and a rounded-rectangle mask cuts the corners.
ann_w=$($IDENTIFY -format "%w" "${annotation}")
ann_h=$($IDENTIFY -format "%h" "${annotation}")
$CONVERT "${annotation}" -alpha set \
         -channel A -fx "0.3 + 0.7 * min(1, abs(0.299*r + 0.587*g + 0.114*b - 0.792) / 0.35)" +channel \
         \( -size "${ann_w}x${ann_h}" xc:none -fill white \
            -draw "roundrectangle 0,0,$((ann_w - 1)),$((ann_h - 1)),16,16" \) \
         -compose DstIn -composite "${annotation}"
# keep it for the pass's other images (mv is atomic, so parallel runs never see half a file)
cp "${annotation}" "${panel}.$$" && mv -f "${panel}.$$" "${panel}"
else
  cp "$panel" "${annotation}"
fi

# resize the annotation, keeping aspect ratio: to ANNOTATION_WIDTH_PERCENT of the
# capture image's width when set, otherwise double its rendered size
if [ -n "${ANNOTATION_WIDTH_PERCENT}" ] && [ "${ANNOTATION_WIDTH_PERCENT%.*}" -gt 0 ] 2>/dev/null; then
  capture_w=$($IDENTIFY -format "%w" "${INPUT_JPG}")
  new_img_w=$(( capture_w * ${ANNOTATION_WIDTH_PERCENT%.*} / 100 ))
  $CONVERT "${annotation}" -resize "${new_img_w}x" "${annotation}"
else
  img_w=$($CONVERT "${annotation}" -format "%w" info:)
  img_h=$($CONVERT "${annotation}" -format "%h" info:)
  new_img_w=$((img_w * 2))
  new_img_h=$((img_h * 2))
  $CONVERT "${annotation}" -resize "${new_img_w}x${new_img_h}^" "${annotation}"
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
