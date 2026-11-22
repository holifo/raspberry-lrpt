#!/bin/bash
#
# The web panel's settings page (Admin > Settings) runs this as the station user, through the
# sudo rule in /etc/sudoers.d/030_www-data-switch (these two commands only):
#
#   scripts/settings_web.sh show    the page's settings and this station's values, as JSON
#   scripts/settings_web.sh apply   save the changes given as JSON on stdin (scripts/tools/settings_form.py)
#
# apply refuses while a pass is being recorded (exit 2). When a change affects the schedule, the
# passes are scheduled again in the background. Settings that need the install wait for
# ./install_and_upgrade.sh; the admin login and the Discord webhook are changed over SSH only.
#
# NOTE: this page has not had a security review. Use it at your own risk, and preferably only
# over HTTPS (docs/tls_webserver.md): the admin login is sent with every request.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  show)
    exec python3 "$REPO/scripts/tools/settings_form.py" show ;;
  apply)
    . "$HOME/.raspberry-lrpt.conf"
    . "$LRPT_HOME/scripts/common.sh"
    if pgrep -f "$METEOR_RUNNING" > /dev/null || pgrep -f "$ISS_RUNNING" > /dev/null; then
      echo '{"ok": false, "busy": true}'
      exit 2
    fi
    result=$(python3 "$LRPT_HOME/scripts/tools/settings_form.py" apply)
    code=$?
    echo "$result"
    [ $code -eq 0 ] || exit $code
    saved=$(python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["saved"]))' <<< "$result")
    [ -z "$saved" ] && exit 0
    log "Settings changed from the web panel: $saved" "INFO" > /dev/null
    if python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["reschedule"] else 1)' <<< "$result"; then
      log "Scheduling the passes again for the new settings" "INFO" > /dev/null
      # in the background: the page shouldn't wait for the TLE download and predict
      nohup flock -n "$LRPT_HOME/tmp/settings-schedule.lock" "$LRPT_HOME/scripts/schedule.sh" -t -x \
        >> "$LRPT_LOG" 2>&1 < /dev/null &
    fi
    exit 0 ;;
  *)
    echo "Usage: $0 show | apply < changes.json"
    exit 1 ;;
esac
