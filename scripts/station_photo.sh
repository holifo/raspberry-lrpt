#!/bin/bash
#
# A photo of the station for the About page's Station tab.
#
#   station_photo.sh                       show what is set
#   station_photo.sh FILE ["caption"]      use FILE (JPG, PNG, HEIC… anything ImageMagick reads)
#   station_photo.sh --caption "text"      change the caption only ("" removes it)
#   station_photo.sh --remove              take the photo off the page
#
# The photo is turned upright, shrunk to 1600 px on its longest side and saved as
# $IMAGE_OUTPUT/station/photo.jpg with ALL its metadata removed (camera EXIF, including any GPS
# position: the About page is public). The caption goes in photo.json next to it.
# To copy a photo from your computer first:  scp mystation.jpg pi@<pi-address>:~/

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

DIR="${IMAGE_OUTPUT}/station"
PHOTO="$DIR/photo.jpg"
META="$DIR/photo.json"

write_meta() {   # caption
  python3 -c 'import json,sys,time; json.dump({"caption": sys.argv[1], "made": int(time.time())}, open(sys.argv[2], "w"))' "$1" "$META.tmp" &&
    chmod 644 "$META.tmp" && mv -f "$META.tmp" "$META"
}
caption_now() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("caption",""))' "$META" 2>/dev/null; }

case "${1:-}" in
  "")
    if [ -f "$PHOTO" ]; then
      echo "Station photo: $PHOTO ($(identify -format '%wx%h' "$PHOTO" 2>/dev/null))"
      echo "Caption      : $(caption_now)"
    else
      echo "No station photo. Add one with: $0 FILE [\"caption\"]"
    fi
    ;;
  -h|--help)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  --remove)
    rm -f "$PHOTO" "$META"
    echo "Station photo removed from the About page."
    log "Station photo removed" "INFO"
    ;;
  --caption)
    [ -f "$PHOTO" ] || { echo "No station photo yet - add one first: $0 FILE [\"caption\"]" >&2; exit 1; }
    write_meta "${2:-}"
    echo "Caption set: ${2:-(none)}"
    ;;
  -*)
    echo "Unknown option $1 (see $0 --help)" >&2; exit 1
    ;;
  *)
    src="$1"
    [ -f "$src" ] || { echo "No such file: $src" >&2; exit 1; }
    mkdir -p "$DIR" || exit 1
    # [0]: the first frame only (an animated GIF or a multi-image HEIC gives one picture)
    if ! convert "${src}[0]" -auto-orient -strip -resize '1600x1600>' -quality 85 "$PHOTO.tmp.jpg" 2>"$DIR/.convert.err"; then
      echo "Could not read $src as a picture: $(tail -1 "$DIR/.convert.err")" >&2
      rm -f "$PHOTO.tmp.jpg" "$DIR/.convert.err"; exit 1
    fi
    rm -f "$DIR/.convert.err"
    chmod 644 "$PHOTO.tmp.jpg" && mv -f "$PHOTO.tmp.jpg" "$PHOTO"
    if [ $# -ge 2 ]; then write_meta "$2"; else write_meta "$(caption_now)"; fi
    echo "Station photo set ($(identify -format '%wx%h' "$PHOTO")): it shows on the About page's Station tab."
    log "Station photo set from $(basename "$src")" "INFO"
    ;;
esac
