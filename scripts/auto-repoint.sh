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
# Per-camera exception (owner decision, 2026-10-05): a camera with
# "trustChannel": true may also apply itself when the replacement is on the
# same channel and is the only live stream there matching its titleMatch,
# whatever its exact title. For operators who retitle every stream (the Table
# Mountain & Lion's Head operator renames each one after it ends and uses
# different day and night titles). More than one match still refuses.
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
mapfile -t rows < <(jq -r '.cameras[] | select(.enabled) | [.id, .name, .streamUrl, (.channelId // ""), (.titleMatch // ""), (.trustChannel == true)] | @tsv' cameras.json)
[ "${#rows[@]}" -eq 0 ] && { echo "No enabled cameras." >&2; finish; }

ids=""
for row in "${rows[@]}"; do
  vid=$(echo "$row" | cut -f3 | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
  ids="${ids:+$ids,}$vid"
done

# liveStreamingDetails costs nothing extra and is the only field that says a
# stream has ended for certain: actualEndTime appears the moment it stops.
resp=$(api "https://www.googleapis.com/youtube/v3/videos?part=snippet,status,liveStreamingDetails&id=${ids}&key=${YT_API_KEY}")
[ -z "$resp" ] && { echo "YouTube Data API call failed; skipping this run." >&2; finish; }

# A stream is only worth showing while it is live now: liveBroadcastContent is
# "live", there is no actualEndTime, and the title does not call it a replay.
# The Table Mountain & Lion's Head operator renames an ended stream to
# "... | LIVE REPLAY", which still contains its titleMatch.
# Used for the current stream and for every candidate, so both sides agree.
LIVE_NOW='(.snippet.liveBroadcastContent == "live")
  and ((.liveStreamingDetails.actualEndTime // "") == "")
  and ((.snippet.title // "") | ascii_downcase | contains("replay") | not)'

# --- 2. For each broken one, find its channel's current live stream -----------
for row in "${rows[@]}"; do
  id=$(echo "$row" | cut -f1)
  name=$(echo "$row" | cut -f2)
  vid=$(echo "$row" | cut -f3 | sed -E 's#.*/embed/([A-Za-z0-9_-]{11}).*#\1#')
  channel=$(echo "$row" | cut -f4)
  match=$(echo "$row" | cut -f5)
  trust=$(echo "$row" | cut -f6)

  old=$(echo "$resp" | jq -c --arg v "$vid" 'first(.items[] | select(.id == $v)) // empty')
  state=$(echo "$old" | jq -r '.snippet.liveBroadcastContent // empty' 2>/dev/null)
  embeddable=$(echo "$old" | jq -r '.status.embeddable // empty' 2>/dev/null)
  old_title=$(echo "$old" | jq -r '.snippet.title // empty' 2>/dev/null)
  old_end=$(echo "$old" | jq -r '.liveStreamingDetails.actualEndTime // empty' 2>/dev/null)
  old_start=$(echo "$old" | jq -r '.liveStreamingDetails.actualStartTime // empty' 2>/dev/null)
  live_now=$(echo "$old" | jq -r "if . == null then false else ${LIVE_NOW} end" 2>/dev/null)

  # Healthy: live now and embeddable. Leave it alone.
  if [ "$live_now" = "true" ] && [ "$embeddable" = "true" ]; then
    continue
  fi

  if [ -z "$state" ]; then
    reason="video no longer exists or is private"
  elif [ "$state" != "live" ]; then
    reason="stream ended (liveBroadcastContent=${state})"
  elif [ -n "$old_end" ]; then
    reason="stream ended at ${old_end} (liveBroadcastContent still said live)"
  elif [ "$live_now" != "true" ]; then
    reason="stream is a replay (\"${old_title}\")"
  else
    reason="live but the owner disabled embedding"
  fi

  if [ -z "$channel" ] || [ -z "$match" ]; then
    printf -- '- **%s** (`%s`): %s. No `channelId`/`titleMatch` in the pack, so no replacement could be looked up. Needs a manual check.\n' \
      "$name" "$id" "$reason" >> "$SUMMARY_FILE"
    continue
  fi

  # Candidates come from two places, and neither is trusted on its own.
  # search costs 100 quota units, so it only runs for cameras that are broken.
  # Its results are cached: on 2026-10-08 it missed a stream live for hours,
  # and it can still list a stream that has ended. The channel's uploads
  # playlist (2 units) is not cached that way, so its newest entries are always
  # added. A channel can run several cameras (Vanilla runs three), so only
  # titles matching the camera's own titleMatch count.
  search=$(api "https://www.googleapis.com/youtube/v3/search?part=snippet&channelId=${channel}&eventType=live&type=video&maxResults=25&key=${YT_API_KEY}")
  search_ids=""
  if [ -n "$search" ]; then
    search_ids=$(echo "$search" | jq -r --arg m "$match" \
      '[.items[]? | select(.snippet.title | ascii_downcase | contains($m | ascii_downcase)) | .id.videoId] | join(",")' 2>/dev/null)
  fi
  recent=$(api "https://www.googleapis.com/youtube/v3/playlistItems?part=contentDetails&playlistId=UU${channel#UC}&maxResults=10&key=${YT_API_KEY}")
  recent_ids=$(echo "$recent" | jq -r '[.items[]?.contentDetails.videoId] | join(",")' 2>/dev/null)

  if [ -z "$search" ] && [ -z "$recent_ids" ]; then
    printf -- '- **%s** (`%s`): %s. Channel search and the uploads lookup both failed this run; will retry.\n' "$name" "$id" "$reason" >> "$SUMMARY_FILE"
    continue
  fi

  # Every candidate is confirmed directly before it counts, so a stale search
  # hit can neither be picked nor make a real replacement look ambiguous.
  cand_ids=$(printf '%s\n' "$search_ids" "$recent_ids" | tr ',' '\n' | grep -v '^$' | grep -vxF "$vid" | awk '!seen[$0]++' | paste -sd, -)
  hits=()
  rejected=""
  if [ -n "$cand_ids" ]; then
    details=$(api "https://www.googleapis.com/youtube/v3/videos?part=snippet,status,liveStreamingDetails&id=${cand_ids}&key=${YT_API_KEY}")
    # Never move a camera to a stream that started before the one it replaces:
    # that is an older broadcast, not the operator's restart.
    mapfile -t hits < <(echo "$details" | jq -r --arg m "$match" --arg since "$old_start" \
      ".items[]? | select(.snippet.title | ascii_downcase | contains(\$m | ascii_downcase))
        | select(${LIVE_NOW})
        | select(\$since == \"\" or (.liveStreamingDetails.actualStartTime // \"\") > \$since)
        | [.id, .snippet.title] | @tsv" 2>/dev/null)
    rejected=$(echo "$details" | jq -r --arg m "$match" --arg since "$old_start" \
      "[.items[]? | select(.snippet.title | ascii_downcase | contains(\$m | ascii_downcase))
        | select((${LIVE_NOW}) and (\$since == \"\" or (.liveStreamingDetails.actualStartTime // \"\") > \$since) | not)
        | \"\`\" + .id + \"\` (\" + (if .liveStreamingDetails.actualEndTime then \"ended\"
            elif .snippet.liveBroadcastContent != \"live\" then \"not live\"
            elif (.snippet.title | ascii_downcase | contains(\"replay\")) then \"replay\"
            else \"started before the current stream\" end) + \")\"] | join(\", \")" 2>/dev/null)
  fi
  ignored=""
  [ -n "$rejected" ] && ignored=" Ignored: ${rejected}."

  if [ "${#hits[@]}" -eq 0 ]; then
    printf -- '- **%s** (`%s`): %s. No live stream on the channel matching `%s` (checked search and the channel'"'"'s newest uploads).%s The camera may be genuinely gone.\n' \
      "$name" "$id" "$reason" "$match" "$ignored" >> "$SUMMARY_FILE"
    continue
  fi
  if [ "${#hits[@]}" -gt 1 ]; then
    printf -- '- **%s** (`%s`): %s. %d live streams match `%s`, so the right one is ambiguous. Not guessing.\n' \
      "$name" "$id" "$reason" "${#hits[@]}" "$match" >> "$SUMMARY_FILE"
    continue
  fi

  new_vid=$(echo "${hits[0]}" | cut -f1)
  check=$(echo "$details" | jq -c --arg v "$new_vid" 'first(.items[] | select(.id == $v))')
  new_embed=$(echo "$check" | jq -r '.status.embeddable // empty')
  new_title=$(echo "$check" | jq -r '.snippet.title // empty')
  new_channel=$(echo "$check" | jq -r '.snippet.channelId // empty')

  # Embeddable matters as much as live: a stream that plays on YouTube but
  # refuses to embed is the exact trap that disabled three cameras.
  if [ "$new_embed" != "true" ]; then
    printf -- '- **%s** (`%s`): %s. Candidate `%s` rejected (live=live, embeddable=%s).\n' \
      "$name" "$id" "$reason" "$new_vid" "${new_embed:-missing}" >> "$SUMMARY_FILE"
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
  elif [ "$trust" = "true" ] && [ "$new_channel" = "$channel" ]; then
    # Uniqueness is already guaranteed: more than one match stopped above.
    verdict="Same channel and the only live stream matching \`${match}\`, and this camera has \`trustChannel\`, so this change may merge itself."
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
