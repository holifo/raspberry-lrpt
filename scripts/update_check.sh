#!/bin/bash
#
# Is there a newer Raspberry-LRPT? (update_check; daily from cron and at the end of each install)
#
# Runs `git fetch` in the station's own clone (read-only: nothing is pulled or installed) and writes
# $IMAGE_OUTPUT/update.json for the web panel's About page and footer:
#
#   status     ok (up to date) | update (newer commits on GitHub) | install (pulled, but
#              install_and_upgrade.sh not run since) | error (the check failed) | off
#   installed  the version the web panel runs ($WEB_HOME/VERSION)
#   repo       the version in ~/raspberry-lrpt (VERSION)
#   latest     the version on GitHub (VERSION on the upstream branch)
#   behind     how many commits the clone is behind GitHub
#   dirty      tracked files changed on the station (git pull may refuse to update them)
#   releases   https://github.com/<owner>/<repo>/releases (from the clone's origin, no credentials)
#   checked    when this ran; error: why it failed
#
#   update_check.sh          check now (prints the result too)

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

OUT="${IMAGE_OUTPUT}/update.json"
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

write() {   # status latest behind error
  local releases=""
  # the GitHub address without any user name or token that may be stored in the remote URL
  releases=$(git -C "$LRPT_HOME" remote get-url origin 2>/dev/null |
    sed -E 's#^(https?://)[^@/]*@#\1#; s#^git@github\.com:#https://github.com/#; s#\.git$##' |
    grep -E '^https://github\.com/[^/]+/[^/]+$' | sed 's#$#/releases#')
  cat > "$OUT.tmp" <<EOF
{"status": "$1", "installed": $(json_str "$(head -1 "$WEB_HOME/VERSION" 2>/dev/null | tr -d '[:space:]')"), "repo": $(json_str "$(head -1 "$LRPT_HOME/VERSION" 2>/dev/null | tr -d '[:space:]')"),
 "latest": $(json_str "$2"), "behind": ${3:-0}, "dirty": ${dirty:-0}, "releases": $(json_str "$releases"),
 "checked": $(date +%s), "error": $(json_str "$4")}
EOF
  chmod 644 "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
  echo "Update check: $1${2:+ (latest v$2)}${4:+ - $4}"
}

if [ "${UPDATE_CHECK:-true}" != "true" ]; then
  write off "" 0 ""
  exit 0
fi
if ! git -C "$LRPT_HOME" rev-parse --git-dir >/dev/null 2>&1; then
  write error "" 0 "$LRPT_HOME is not a git clone"
  exit 0
fi

dirty=$(git -C "$LRPT_HOME" status --porcelain --untracked-files=no 2>/dev/null | wc -l)
if ! err=$(GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$LRPT_HOME" -c credential.interactive=never fetch --quiet origin 2>&1); then
  err=$(echo "$err" | sed -E 's#https?://[^@ ]*@#https://#g' | tail -1)
  log "Update check failed: ${err:-git fetch failed}" "WARN"
  write error "" 0 "${err:-git fetch failed}"
  exit 0
fi

upstream=$(git -C "$LRPT_HOME" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
if [ -z "$upstream" ]; then
  write error "" 0 "the branch has no upstream on GitHub"
  exit 0
fi
behind=$(git -C "$LRPT_HOME" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
latest=$(git -C "$LRPT_HOME" show "$upstream:VERSION" 2>/dev/null | tr -d '[:space:]')

if [ "$behind" -gt 0 ]; then
  write update "$latest" "$behind" ""
  log "Update available: v${latest} on GitHub (${behind} new commits). Update: cd ~/raspberry-lrpt && git pull && ./install_and_upgrade.sh" "INFO"
elif [ "$(cat "$LRPT_HOME/VERSION" 2>/dev/null)" != "$(cat "$WEB_HOME/VERSION" 2>/dev/null)" ]; then
  write install "$latest" 0 ""
else
  write ok "$latest" 0 ""
fi
