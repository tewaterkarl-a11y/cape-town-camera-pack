#!/usr/bin/env bash
# Health check for Cape Town Window: site uptime + YouTube liveness per camera.
# Writes a failure report to $REPORT_FILE (one line per problem) and exits 0;
# the workflow decides whether to open/close the alert issue.
set -u

SITE_URL="https://capetownwindow.com"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
REPORT_FILE="${REPORT_FILE:-report.txt}"
: > "$REPORT_FILE"

# --- 1. Site uptime -----------------------------------------------------------
site_ok=true
if ! curl -fsS --max-time 20 "$SITE_URL" | grep -q "Cape Town Window"; then
  sleep 5
  if ! curl -fsS --max-time 20 "$SITE_URL" | grep -q "Cape Town Window"; then
    site_ok=false
    echo "SITE DOWN: $SITE_URL did not return the app (checked twice)" >> "$REPORT_FILE"
  fi
fi

# --- 2. Camera liveness (YouTube-aware: isLiveNow, not URL reachability) -------
check_camera() {
  local id="$1" name="$2" video_id="$3"
  local html
  html=$(curl -fsS --max-time 20 -A "$UA" -H "Accept-Language: en" \
    "https://www.youtube.com/watch?v=${video_id}" 2>/dev/null) || return 2
  if echo "$html" | grep -q '"isLiveNow":true'; then
    if echo "$html" | grep -q '"playableInEmbed":false'; then
      return 3  # live but embedding disabled
    fi
    return 0
  fi
  return 1
}

total=0
failed_ids=()
while IFS=$'\t' read -r id name url; do
  video_id=$(echo "$url" | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
  total=$((total + 1))
  check_camera "$id" "$name" "$video_id"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    sleep 10  # one retry; transient fetch issues are common from CI runners
    check_camera "$id" "$name" "$video_id"
    rc=$?
  fi
  case "$rc" in
    1) failed_ids+=("CAMERA NOT LIVE: ${name} (${id}, video ${video_id}) — stream has ended or is offline") ;;
    2) failed_ids+=("CAMERA CHECK FAILED: ${name} (${id}, video ${video_id}) — could not fetch watch page") ;;
    3) failed_ids+=("CAMERA NOT EMBEDDABLE: ${name} (${id}, video ${video_id}) — live but embedding disabled") ;;
  esac
done < <(jq -r '.cameras[] | select(.enabled) | [.id, .name, .streamUrl] | @tsv' cameras.json)

# Sanity guard: if EVERY camera failed but the site is up, the runner is almost
# certainly being bot-walled by YouTube. Don't raise a false alarm.
if [ "$total" -gt 0 ] && [ "${#failed_ids[@]}" -eq "$total" ] && [ "$site_ok" = true ]; then
  echo "All ${total} cameras unreadable from this runner — likely YouTube bot wall, not real outages. Skipping camera alerts." >&2
else
  for line in "${failed_ids[@]}"; do
    echo "$line" >> "$REPORT_FILE"
  done
fi

echo "Checked site + ${total} cameras; $(wc -l < "$REPORT_FILE") problem(s) recorded." >&2
exit 0
