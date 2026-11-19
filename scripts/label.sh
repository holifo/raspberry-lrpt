#!/bin/bash
#
# Choose the look of the station label on capture images (docs/annotation.md).
#
#   scripts/label.sh                              show the current look and the styles
#   scripts/label.sh STYLE [TRANSPARENCY]         light | dark | auto | white | black | clear,
#                                                 optionally with 0-100 (% see-through)
#   scripts/label.sh transparency N               0 (solid) to 100 (no panel)
#   scripts/label.sh background|text|border COLOUR   '#rrggbb', or "default" for the style's
#   scripts/label.sh reset                        back to the classic look (light, 70, style colours)
#   scripts/label.sh preview [OUT.png]            draw the label with example values
#                                                 (default tmp/label-preview.png; auto draws both)
#
# It saves the choice in config/settings.local.yml (so the next install keeps it) and refreshes
# the merged settings the label is drawn from. It applies from the next pass; images already made
# keep their label.

LRPT_HOME="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LRPT_HOME" || exit 1
tool=(python3 scripts/tools/settings.py)
merged="config/.settings.merged.yml"

set_() { "${tool[@]}" set "$1" "$2" || exit 1; }
value() {
  python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])) or {}; print(d.get(sys.argv[2], ""))' \
    "$merged" "$1" 2>/dev/null
}

show() {
  [ -f "$merged" ] || "${tool[@]}" merged "$merged"
  echo "Label: style $(value annotation_style), $(value annotation_transparency)% see-through" \
       "(background: $(value annotation_background | sed 's/^$/style/'), text: $(value annotation_text_colour | sed 's/^$/style/')," \
       "border: $(value annotation_border_colour | sed 's/^$/style/'))"
  cat <<'EOF'

Styles:
  light   light grey panel, black text (the classic)  daytime colour images
  dark    navy panel, white text                      night and IR images
  auto    light for daytime passes, dark at night     a station that records day and night
  white   white panel, black text                     sharing and printing (try transparency 0-20)
  black   black panel, white text                     the black band of extend_for_annotation
  clear   no panel, outlined white text               covering as little of the picture as possible

Change with: scripts/label.sh STYLE [TRANSPARENCY] | transparency N | background|text|border '#rrggbb'|default
             scripts/label.sh preview   to see it
EOF
}

preview() {
  local out="${1:-$LRPT_HOME/tmp/label-preview.png}" sun
  mkdir -p "$(dirname "$out")"
  [ -f "$merged" ] || "${tool[@]}" merged "$merged"
  draw() {
    python3 scripts/image_processors/annotation_panel.py "$merged" config/annotation/annotation.yml "$1" \
      "sat_name=METEOR-M2 4" "capture_start=$(date '+%d-%m-%Y %H:%M')" sat_max_elevation=52 \
      "sun_elevation=$2" pass_direction=Northbound pass_side=E pass_side_long=East gain=48 || exit 1
    echo "Drawn: $1"
  }
  if [ "$(value annotation_style)" == "auto" ]; then
    draw "${out%.png}-day.png" 34
    draw "${out%.png}-night.png" -20
  else
    draw "$out" 34
  fi
}

case "${1:-}" in
  "")              show; exit 0 ;;
  preview)         preview "${2:-}"; exit 0 ;;
  light|dark|auto|white|black|clear)
                   set_ annotation_style "$1"
                   [ -n "${2:-}" ] && set_ annotation_transparency "$2" ;;
  transparency)    [ -n "${2:-}" ] || { echo "Usage: $0 transparency 0-100"; exit 1; }
                   set_ annotation_transparency "$2" ;;
  background|text|border)
                   key="annotation_${1}_colour"; [ "$1" == "background" ] && key="annotation_background"
                   colour="${2:-}"; [ "$colour" == "default" ] && colour=""
                   [ -n "${2:-}" ] || { echo "Usage: $0 $1 '#rrggbb'|default"; exit 1; }
                   set_ "$key" "$colour" ;;
  reset)           set_ annotation_style light; set_ annotation_transparency 70
                   for k in annotation_background annotation_text_colour annotation_border_colour; do set_ "$k" ""; done ;;
  *)               echo "Unknown option: $1"; echo; show; exit 1 ;;
esac

"${tool[@]}" merged "$merged" || exit 1
show | head -1
echo "It applies from the next pass. See it now with: scripts/label.sh preview"
