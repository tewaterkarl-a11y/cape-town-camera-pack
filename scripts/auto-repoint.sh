#!/usr/bin/env bash
# Propose replacement video IDs for enabled cameras whose stream has died.
#
# Why this exists: three times in three weeks a camera "broke" and the fix was
# always the same, the operator had restarted the same physical camera under a
# new YouTube video ID. The monitor could tell us it was dead but not what to
# do about it, so every failure cost a manual investigation.
#
# Finding the replacement is deterministic, so this script does it and writes
# the result into cameras.json. The workflow opens a PR with the change.
#
# When the PR may merge itself (owner decision, 2026-09-13): only when EVERY
# camera it changes was replaced by a stream on the same YouTube channel with
# exactly the same title as the stream that died. That is the operator
# restarting the same camera. Anything else (a renamed stream, a deleted old
# video whose title cannot be compared) waits for a person to check the view.
#
# Writes a markdown summary to $SUMMARY_FILE and edits cameras.json in place.
# Sets `changed=<n>` and `automerge=true|false` in $GITHUB_OUTPUT.
# Exits 0 whether or not it found anything; the workflow decides what to do.
set -u

SUMMARY_FILE="${SUMMARY_FILE:-repoint-summary.md}"
: > "$SUMMARY_FILE"
CHANGED=0
NEEDS_REVIEW=0

finish() {
  local automerge=false
  if [ "$CHANGED" -gt 0 ] && [ "$NEEDS_REVIEW" -eq 0 ]; then automerge=true; fi
  {
    echo "changed=${CHANGED}"
    echo "automerge=${automerge}"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "Auto-repoint finished; ${CHANGED} camera(s) rewritten, automerge=${automerge}." >&2
  exit 0
}

if [ -z "${YT_API_KEY:-}" ]; then
  echo "YT_API_KEY is not set; cannot check cameras from CI. Skipping." >&2
  finish
fi

api() { curl -fsS --max-time 20 "$1" 2>/dev/null; }

# --- 1. Which enabled cameras are currently broken? ---------------------------
mapfile -t rows < <(jq -r '.cameras[] | select(.enabled) | [.id, .name, .streamUrl, (.channelId // ""), (.titleMatch // "")] | @tsv' cameras.json)
[ "${#rows[@]}" -eq 0 ] && { echo "No enabled cameras." >&2; finish; }

ids=""
for row in "${rows[@]}"; do
  vid=$(echo "$row" | cut -f3 | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
  ids="${ids:+$ids,}$vid"
done

resp=$(api "https://www.googleapis.com/youtube/v3/videos?part=snippet,status&id=${ids}&key=${YT_API_KEY}")
[ -z "$resp" ] && { echo "YouTube Data API call failed; skipping this run." >&2; finish; }

# --- 2. For each broken one, find its channel's current live stream -----------
for row in "${rows[@]}"; do
  id=$(echo "$row" | cut -f1)
  name=$(echo "$row" | cut -f2)
  vid=$(echo "$row" | cut -f3 | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
  channel=$(echo "$row" | cut -f4)
  match=$(echo "$row" | cut -f5)

  state=$(echo "$resp" | jq -r --arg v "$vid" '.items[] | select(.id == $v) | .snippet.liveBroadcastContent // empty')
  embeddable=$(echo "$resp" | jq -r --arg v "$vid" '.items[] | select(.id == $v) | .status.embeddable // empty')
  old_title=$(echo "$resp" | jq -r --arg v "$vid" '.items[] | select(.id == $v) | .snippet.title // empty')

  # Healthy: live and embeddable. Leave it alone.
  if [ "$state" = "live" ] && [ "$embeddable" = "true" ]; then
    continue
  fi

  if [ -z "$state" ]; then
    reason="video no longer exists or is private"
  elif [ "$state" != "live" ]; then
    reason="stream ended (liveBroadcastContent=${state})"
  else
    reason="live but the owner disabled embedding"
  fi

  if [ -z "$channel" ] || [ -z "$match" ]; then
    printf -- '- **%s** (`%s`): %s. No `channelId`/`titleMatch` in the pack, so no replacement could be looked up. Needs a manual check.\n' \
      "$name" "$id" "$reason" >> "$SUMMARY_FILE"
    continue
  fi

  # search costs 100 quota units, so it only runs for cameras that are broken.
  # A channel can run several cameras (Vanilla runs three), so filter the live
  # results by the camera's own titleMatch rather than taking the first hit.
  search=$(api "https://www.googleapis.com/youtube/v3/search?part=snippet&channelId=${channel}&eventType=live&type=video&maxResults=25&key=${YT_API_KEY}")
  if [ -z "$search" ]; then
    printf -- '- **%s** (`%s`): %s. Channel search failed this run; will retry.\n' "$name" "$id" "$reason" >> "$SUMMARY_FILE"
    continue
  fi

  mapfile -t hits < <(echo "$search" | jq -r --arg m "$match" \
    '.items[] | select(.snippet.title | ascii_downcase | contains($m | ascii_downcase)) | [.id.videoId, .snippet.title] | @tsv')

  if [ "${#hits[@]}" -eq 0 ]; then
    printf -- '- **%s** (`%s`): %s. No live stream on the channel matching `%s`. The camera may be genuinely gone.\n' \
      "$name" "$id" "$reason" "$match" >> "$SUMMARY_FILE"
    continue
  fi
  if [ "${#hits[@]}" -gt 1 ]; then
    printf -- '- **%s** (`%s`): %s. %d live streams match `%s`, so the right one is ambiguous. Not guessing.\n' \
      "$name" "$id" "$reason" "${#hits[@]}" "$match" >> "$SUMMARY_FILE"
    continue
  fi

  new_vid=$(echo "${hits[0]}" | cut -f1)

  # search results can lag reality, so confirm the candidate directly before
  # proposing it. Embeddable matters as much as live: a stream that plays on
  # YouTube but refuses to embed is the exact trap that disabled three cameras.
  check=$(api "https://www.googleapis.com/youtube/v3/videos?part=snippet,status&id=${new_vid}&key=${YT_API_KEY}")
  new_state=$(echo "$check" | jq -r '.items[0].snippet.liveBroadcastContent // empty')
  new_embed=$(echo "$check" | jq -r '.items[0].status.embeddable // empty')
  new_title=$(echo "$check" | jq -r '.items[0].snippet.title // empty')
  new_channel=$(echo "$check" | jq -r '.items[0].snippet.channelId // empty')

  if [ "$new_state" != "live" ] || [ "$new_embed" != "true" ]; then
    printf -- '- **%s** (`%s`): %s. Candidate `%s` rejected (live=%s, embeddable=%s).\n' \
      "$name" "$id" "$reason" "$new_vid" "${new_state:-missing}" "${new_embed:-missing}" >> "$SUMMARY_FILE"
    continue
  fi

  tmp=$(mktemp)
  jq --indent 2 --arg id "$id" --arg url "https://www.youtube.com/embed/${new_vid}" \
    '(.cameras[] | select(.id == $id) | .streamUrl) = $url' cameras.json > "$tmp" && mv "$tmp" cameras.json
  CHANGED=$((CHANGED + 1))

  # Same channel and an identical title means the operator restarted the same
  # camera. Compared exactly: a date or place added to the title is enough to
  # send the change to a person.
  if [ -n "$old_title" ] && [ "$old_title" = "$new_title" ] && [ "$new_channel" = "$channel" ]; then
    verdict="Same channel and exactly the same title as the stream that died, so this change may merge itself."
  else
    NEEDS_REVIEW=$((NEEDS_REVIEW + 1))
    if [ -z "$old_title" ]; then
      verdict="The old video is gone, so its title cannot be compared. **Needs a person to check the view.**"
    elif [ "$new_channel" != "$channel" ]; then
      verdict="The candidate is on a different channel (\`${new_channel:-unknown}\`). **Needs a person to check the view.**"
    else
      verdict="The title changed from \"${old_title}\". **Needs a person to check the view.**"
    fi
  fi

  printf -- '- **%s** (`%s`): %s. Repointed `%s` → `%s`\n  - New stream: "%s"\n  - Confirmed live and embeddable via the Data API.\n  - %s\n' \
    "$name" "$id" "$reason" "$vid" "$new_vid" "$new_title" "$verdict" >> "$SUMMARY_FILE"
done

if [ "$CHANGED" -gt 0 ]; then
  today=$(date -u '+%Y-%m-%d')
  tmp=$(mktemp)
  jq --indent 2 --arg d "$today" '.updated = $d' cameras.json > "$tmp" && mv "$tmp" cameras.json
fi

finish
