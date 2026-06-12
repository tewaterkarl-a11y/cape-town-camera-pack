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

# --- 2. Camera liveness (YouTube-aware: isLive, not URL reachability) ----------
# Uses the innertube player endpoint: videoDetails.isLive is true only while a
# stream is actually live, and the endpoint is not consent/bot-walled the way
# watch pages are for datacenter IPs. Falls back to the watch page if needed.
check_camera() {
  local id="$1" name="$2" video_id="$3"
  local resp
  resp=$(curl -fsS --max-time 20 -A "$UA" \
    -H "Content-Type: application/json" \
    -X POST "https://www.youtube.com/youtubei/v1/player" \
    -d "{\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"2.20240101.00.00\"}},\"videoId\":\"${video_id}\"}" \
    2>/dev/null)
  if [ -n "$resp" ] && echo "$resp" | jq -e '.videoDetails != null' >/dev/null 2>&1; then
    if echo "$resp" | jq -e '.videoDetails.isLive == true' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  # Fallback: watch-page scrape (works from residential IPs, often bot-walled in CI)
  local html
  html=$(curl -fsS --max-time 20 -A "$UA" -H "Accept-Language: en" \
    "https://www.youtube.com/watch?v=${video_id}" 2>/dev/null) || return 2
  if echo "$html" | grep -q '"isLiveNow":true'; then
    return 0
  fi
  return 1
}

total=0
failed_ids=()

if [ -n "${YT_API_KEY:-}" ]; then
  # Preferred path: official YouTube Data API. One batched call; reliable from
  # CI (unlike scraping, which YouTube bot-walls for datacenter IPs).
  # snippet.liveBroadcastContent is "live" while streaming, "none" once ended.
  mapfile -t rows < <(jq -r '.cameras[] | select(.enabled) | [.id, .name, .streamUrl] | @tsv' cameras.json)
  ids=""
  for row in "${rows[@]}"; do
    url=$(echo "$row" | cut -f3)
    vid=$(echo "$url" | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
    ids="${ids:+$ids,}$vid"
  done
  total=${#rows[@]}
  api_resp=$(curl -fsS --max-time 20 \
    "https://www.googleapis.com/youtube/v3/videos?part=snippet&id=${ids}&key=${YT_API_KEY}" 2>/dev/null)
  if [ -z "$api_resp" ]; then
    echo "YouTube Data API call failed — skipping camera checks this run." >&2
  else
    for row in "${rows[@]}"; do
      id=$(echo "$row" | cut -f1); name=$(echo "$row" | cut -f2); url=$(echo "$row" | cut -f3)
      vid=$(echo "$url" | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
      state=$(echo "$api_resp" | jq -r --arg v "$vid" '.items[] | select(.id == $v) | .snippet.liveBroadcastContent // "missing"')
      if [ -z "$state" ]; then
        failed_ids+=("CAMERA REMOVED: ${name} (${id}, video ${vid}) — video no longer exists or is private")
      elif [ "$state" != "live" ]; then
        failed_ids+=("CAMERA NOT LIVE: ${name} (${id}, video ${vid}) — liveBroadcastContent=${state}")
      fi
    done
    checks_trusted=true  # API answers are real data; no bot-wall ambiguity
  fi
else
  # Fallback path (no API key): scrape-based checks. YouTube usually bot-walls
  # CI runners, in which case the guard below skips camera alerts entirely.
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
      2) failed_ids+=("CAMERA CHECK FAILED: ${name} (${id}, video ${video_id}) — could not reach YouTube for this video") ;;
    esac
  done < <(jq -r '.cameras[] | select(.enabled) | [.id, .name, .streamUrl] | @tsv' cameras.json)
fi

# Sanity guard (scrape path only): if EVERY camera failed but the site is up,
# the runner is almost certainly being bot-walled by YouTube. Don't raise a
# false alarm. API results are trusted as-is.
if [ "${checks_trusted:-false}" != true ] && [ "$total" -gt 0 ] && \
   [ "${#failed_ids[@]}" -eq "$total" ] && [ "$site_ok" = true ]; then
  echo "All ${total} cameras unreadable from this runner — likely YouTube bot wall, not real outages. Skipping camera alerts." >&2
else
  for line in "${failed_ids[@]}"; do
    echo "$line" >> "$REPORT_FILE"
  done
fi

echo "Checked site + ${total} cameras; $(wc -l < "$REPORT_FILE") problem(s) recorded." >&2
exit 0
