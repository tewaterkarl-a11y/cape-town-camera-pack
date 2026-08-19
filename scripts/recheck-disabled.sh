#!/usr/bin/env bash
# Weekly re-check of cameras that are switched off in cameras.json.
#
# The main monitor (scripts/check.sh) only looks at enabled cameras, by design:
# it answers "is the site healthy right now". That leaves a blind spot. A camera
# disabled because its owner turned off embedding can be fixed by that owner at
# any time and nobody would ever know. Clifton and Milnerton came back on air in
# 2026 and sat unnoticed for six weeks.
#
# This script answers the opposite question: "has anything we gave up on become
# usable again". It writes one line per restorable camera to $REPORT_FILE and
# exits 0. Silence is the normal result; the workflow only speaks up when the
# file is non-empty.
set -u

REPORT_FILE="${REPORT_FILE:-restorable.txt}"
: > "$REPORT_FILE"

if [ -z "${YT_API_KEY:-}" ]; then
  # The scrape and innertube fallbacks are bot-walled for GitHub's datacenter
  # IPs, so without the key this check can only produce false negatives.
  # Say so and stop rather than report a comforting empty result.
  echo "YT_API_KEY is not set; cannot re-check disabled cameras from CI. Skipping." >&2
  exit 0
fi

mapfile -t rows < <(jq -r '.cameras[] | select(.enabled | not) | [.id, .name, .streamUrl] | @tsv' cameras.json)
if [ "${#rows[@]}" -eq 0 ]; then
  echo "No disabled cameras to re-check." >&2
  exit 0
fi

ids=""
for row in "${rows[@]}"; do
  url=$(echo "$row" | cut -f3)
  vid=$(echo "$url" | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
  ids="${ids:+$ids,}$vid"
done

api_resp=$(curl -fsS --max-time 20 \
  "https://www.googleapis.com/youtube/v3/videos?part=snippet,status&id=${ids}&key=${YT_API_KEY}" 2>/dev/null)
if [ -z "$api_resp" ]; then
  echo "YouTube Data API call failed; skipping this run." >&2
  exit 0
fi

restorable=0
for row in "${rows[@]}"; do
  id=$(echo "$row" | cut -f1); name=$(echo "$row" | cut -f2); url=$(echo "$row" | cut -f3)
  vid=$(echo "$url" | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
  state=$(echo "$api_resp" | jq -r --arg v "$vid" '.items[] | select(.id == $v) | .snippet.liveBroadcastContent // empty')
  embeddable=$(echo "$api_resp" | jq -r --arg v "$vid" '.items[] | select(.id == $v) | .status.embeddable // empty')

  # Both conditions must hold. Live but not embeddable is the exact trap that
  # put most of these cameras on the disabled list in the first place.
  if [ "$state" = "live" ] && [ "$embeddable" = "true" ]; then
    echo "RESTORABLE: ${name} (${id}, video ${vid}) — live again and embedding is back on" >> "$REPORT_FILE"
    restorable=$((restorable + 1))
  fi
done

echo "Re-checked ${#rows[@]} disabled camera(s); ${restorable} restorable." >&2
exit 0
