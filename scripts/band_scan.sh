#!/bin/bash
#
# Band scans (Admin > Band scan): look at a band with rtl_power for a while on one of the
# station's RTL-SDRs. The web panel runs this as the station user, through the sudo rule in
# /etc/sudoers.d/030_www-data-switch (these four commands only):
#
#   scripts/band_scan.sh status          the presets, dongles, the scan running and the kept scans (JSON)
#   scripts/band_scan.sh start  < JSON   {"preset": "meteor|2m|70cm|vhf|fm", "minutes": 2|5|10|30|60, "device": N}
#   scripts/band_scan.sh stop            stop the scan running; what it recorded is still drawn
#   scripts/band_scan.sh delete < JSON   {"id": "..."}
#
# A scan is refused while a pass is recording on that dongle or would start during the scan, and
# a pass that starts anyway stops it (receive_meteor.sh / receive_iss.sh). The pictures are kept in
# /srv/scans, which the web server does not serve: only the admin page shows them.

set -a
[ -f "$HOME/.raspberry-lrpt.conf" ] && . "$HOME/.raspberry-lrpt.conf"
set +a
here="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  status|start|stop|delete) exec python3 "${LRPT_HOME:-$here}/scripts/tools/band_scan.py" "$1" ;;
  *) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
