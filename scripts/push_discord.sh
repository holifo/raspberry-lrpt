#!/bin/bash
#
# Posts a message with images to a Discord channel through a webhook (settings: discord_webhook,
# discord_site_url, discord_images, discord_sky_track). Called by receive_meteor.sh after each
# pass that made images. Does nothing when discord_webhook is empty.
#
#   push_discord.sh MESSAGE [IMAGE ...]    post MESSAGE with up to 10 images
#   push_discord.sh --test                 post a test message, to check the webhook
#
# The webhook URL is a password: anyone who has it can post to the channel. It is kept in
# config/settings.local.yml (not tracked) and never written to the log.

. "$HOME/.raspberry-lrpt.conf"
. "$LRPT_HOME/scripts/common.sh"

DISCORD_MAX_BYTES=$((9 * 1024 * 1024))    # Discord's limit for a webhook file is 10 MB

if [ -z "${DISCORD_WEBHOOK}" ]; then
  [ "$1" == "--test" ] && echo "discord_webhook is not set - run ./install_and_upgrade.sh and answer the Discord question"
  exit 0
fi

if [ "$1" == "--test" ]; then
  set -- "Test message from ${STATION_TITLE:-Raspberry-LRPT}: Discord posting works."
fi
message=$1
shift

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# the images, made smaller when they are over Discord's size limit
files=()
for image in "$@"; do
  [ -f "$image" ] || continue
  [ ${#files[@]} -ge 10 ] && break
  if [ "$(stat -c %s "$image")" -gt "$DISCORD_MAX_BYTES" ]; then
    small="$work/$(basename "${image%.*}").jpg"
    for size in 75% 55% 40% 30%; do
      convert "$image" -resize "$size" -quality 85 "$small" 2>/dev/null
      [ "$(stat -c %s "$small" 2>/dev/null || echo 0)" -le "$DISCORD_MAX_BYTES" ] && break
    done
    image=$small
  fi
  files+=("$image")
done

payload=$(python3 -c 'import json, sys; print(json.dumps({"content": sys.argv[1][:2000]}))' "$message")
form=(-F "payload_json=${payload}")
i=0
for f in "${files[@]}"; do
  form+=(-F "files[$i]=@${f}")
  i=$((i + 1))
done

# post; on "too many requests" wait as long as Discord asks and try once more
for attempt in 1 2; do
  code=$(curl -s -o "$work/reply" -w '%{http_code}' --max-time 120 "${form[@]}" "${DISCORD_WEBHOOK}")
  if [ "$code" == "429" ] && [ $attempt -eq 1 ]; then
    wait_s=$(python3 -c 'import json, sys; print(min(60, int(float(json.load(open(sys.argv[1])).get("retry_after", 5))) + 1))' "$work/reply" 2>/dev/null || echo 5)
    log "Discord asked to wait ${wait_s} s before posting" "WARN"
    sleep "$wait_s"
    continue
  fi
  break
done

if [[ "$code" == 2* ]]; then
  log "Posted to Discord with ${#files[@]} image(s)" "INFO"
  [ "$message" != "${message#Test message}" ] && echo "Posted a test message to Discord"
  exit 0
fi
reason=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("message", ""))' "$work/reply" 2>/dev/null)
log "Discord post failed (HTTP ${code:-none}${reason:+: $reason})" "WARN"
[ "$message" != "${message#Test message}" ] && echo "Discord post failed (HTTP ${code:-none}${reason:+: $reason})"
exit 1
