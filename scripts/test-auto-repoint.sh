#!/usr/bin/env bash
# Tests for scripts/auto-repoint.sh, with the YouTube Data API faked.
#
# Each case writes a small cameras.json and the API responses it should see,
# puts a fake `curl` first on PATH, runs the real script and checks what it
# decided. Run locally or in CI: bash scripts/test-auto-repoint.sh (needs jq).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILURES=0

# A fake curl that answers from $FIXTURES instead of the network.
# videos?...&id=<one id> -> video-<id>.json if present, else videos.json
# search?...             -> search.json
make_fake_curl() {
  mkdir -p "$1"
  cat > "$1/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *"/search?"*) cat "$FIXTURES/search.json" ;;
  *"/videos?"*)
    id=$(echo "$url" | sed -E 's#.*[?&]id=([^&]+).*#\1#')
    if [ -f "$FIXTURES/video-$id.json" ]; then cat "$FIXTURES/video-$id.json"; else cat "$FIXTURES/videos.json"; fi ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$1/curl"
}

video() { # id title state embeddable channel
  printf '{"id":"%s","snippet":{"title":"%s","liveBroadcastContent":"%s","channelId":"%s"},"status":{"embeddable":%s}}' "$1" "$2" "$3" "$5" "$4"
}

# run_case <name> ; expects $WORK prepared with cameras.json and $FIXTURES
run_case() {
  local out
  out=$(cd "$WORK" && FIXTURES="$FIXTURES" PATH="$WORK/bin:$PATH" YT_API_KEY=test GITHUB_OUTPUT="$WORK/output" \
    SUMMARY_FILE="$WORK/summary.md" bash "$ROOT/scripts/auto-repoint.sh" 2>&1)
  CHANGED=$(grep '^changed=' "$WORK/output" | tail -1 | cut -d= -f2)
  AUTOMERGE=$(grep '^automerge=' "$WORK/output" | tail -1 | cut -d= -f2)
  URL_OF() { jq -r --arg id "$1" '.cameras[] | select(.id == $id) | .streamUrl' "$WORK/cameras.json"; }
}

expect() { # description actual expected
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: expected '$3', got '$2'"
    FAILURES=$((FAILURES + 1))
  fi
}

setup() { # camera definitions as JSON array
  WORK=$(mktemp -d)
  FIXTURES="$WORK/fixtures"
  mkdir -p "$FIXTURES"
  make_fake_curl "$WORK/bin"
  printf '{"version":"1.9","updated":"2026-09-09","cameras":%s}\n' "$1" > "$WORK/cameras.json"
}

CAM_A='{"id":"sea-point","name":"Sea Point","type":"youtube","streamUrl":"https://www.youtube.com/embed/OLDaaaaaaaa","enabled":true,"channelId":"UCvanilla","titleMatch":"Sea Point"}'
CAM_B='{"id":"cbd","name":"CBD","type":"youtube","streamUrl":"https://www.youtube.com/embed/OLDbbbbbbbb","enabled":true,"channelId":"UCvanilla","titleMatch":"CBD"}'

echo "Same channel, exactly the same title: repoint and allow the merge"
setup "[$CAM_A]"
echo "{\"items\":[$(video OLDaaaaaaaa 'Sea Point Live' none true UCvanilla)]}" > "$FIXTURES/videos.json"
echo '{"items":[{"id":{"videoId":"NEWaaaaaaaa"},"snippet":{"title":"Sea Point Live"}}]}' > "$FIXTURES/search.json"
echo "{\"items\":[$(video NEWaaaaaaaa 'Sea Point Live' live true UCvanilla)]}" > "$FIXTURES/video-NEWaaaaaaaa.json"
run_case
expect "one camera changed" "$CHANGED" 1
expect "automerge allowed" "$AUTOMERGE" true
expect "stream URL rewritten" "$(URL_OF sea-point)" "https://www.youtube.com/embed/NEWaaaaaaaa"
expect "summary says it may merge itself" "$(grep -c 'may merge itself' "$WORK/summary.md")" 1

echo "Title changed: repoint but wait for a person"
setup "[$CAM_A]"
echo "{\"items\":[$(video OLDaaaaaaaa 'Sea Point Live' none true UCvanilla)]}" > "$FIXTURES/videos.json"
echo '{"items":[{"id":{"videoId":"NEWaaaaaaaa"},"snippet":{"title":"Sea Point Live 2"}}]}' > "$FIXTURES/search.json"
echo "{\"items\":[$(video NEWaaaaaaaa 'Sea Point Live 2' live true UCvanilla)]}" > "$FIXTURES/video-NEWaaaaaaaa.json"
run_case
expect "one camera changed" "$CHANGED" 1
expect "automerge refused" "$AUTOMERGE" false
expect "summary asks for a person" "$(grep -c 'The title changed' "$WORK/summary.md")" 1

echo "Old video deleted, so no title to compare: wait for a person"
setup "[$CAM_A]"
echo '{"items":[]}' > "$FIXTURES/videos.json"
echo '{"items":[{"id":{"videoId":"NEWaaaaaaaa"},"snippet":{"title":"Sea Point Live"}}]}' > "$FIXTURES/search.json"
echo "{\"items\":[$(video NEWaaaaaaaa 'Sea Point Live' live true UCvanilla)]}" > "$FIXTURES/video-NEWaaaaaaaa.json"
run_case
expect "one camera changed" "$CHANGED" 1
expect "automerge refused" "$AUTOMERGE" false

echo "Candidate on a different channel: wait for a person"
setup "[$CAM_A]"
echo "{\"items\":[$(video OLDaaaaaaaa 'Sea Point Live' none true UCvanilla)]}" > "$FIXTURES/videos.json"
echo '{"items":[{"id":{"videoId":"NEWaaaaaaaa"},"snippet":{"title":"Sea Point Live"}}]}' > "$FIXTURES/search.json"
echo "{\"items\":[$(video NEWaaaaaaaa 'Sea Point Live' live true UCsomeoneelse)]}" > "$FIXTURES/video-NEWaaaaaaaa.json"
run_case
expect "automerge refused" "$AUTOMERGE" false

echo "Two dead cameras, one renamed: the whole PR waits"
setup "[$CAM_A,$CAM_B]"
echo "{\"items\":[$(video OLDaaaaaaaa 'Sea Point Live' none true UCvanilla),$(video OLDbbbbbbbb 'CBD Live' none true UCvanilla)]}" > "$FIXTURES/videos.json"
echo '{"items":[{"id":{"videoId":"NEWaaaaaaaa"},"snippet":{"title":"Sea Point Live"}},{"id":{"videoId":"NEWbbbbbbbb"},"snippet":{"title":"CBD Live (new)"}}]}' > "$FIXTURES/search.json"
echo "{\"items\":[$(video NEWaaaaaaaa 'Sea Point Live' live true UCvanilla)]}" > "$FIXTURES/video-NEWaaaaaaaa.json"
echo "{\"items\":[$(video NEWbbbbbbbb 'CBD Live (new)' live true UCvanilla)]}" > "$FIXTURES/video-NEWbbbbbbbb.json"
run_case
expect "two cameras changed" "$CHANGED" 2
expect "automerge refused" "$AUTOMERGE" false

echo "Replacement not embeddable: no change at all"
setup "[$CAM_A]"
echo "{\"items\":[$(video OLDaaaaaaaa 'Sea Point Live' none true UCvanilla)]}" > "$FIXTURES/videos.json"
echo '{"items":[{"id":{"videoId":"NEWaaaaaaaa"},"snippet":{"title":"Sea Point Live"}}]}' > "$FIXTURES/search.json"
echo "{\"items\":[$(video NEWaaaaaaaa 'Sea Point Live' live false UCvanilla)]}" > "$FIXTURES/video-NEWaaaaaaaa.json"
run_case
expect "nothing changed" "$CHANGED" 0
expect "automerge not allowed" "$AUTOMERGE" false
expect "stream URL untouched" "$(URL_OF sea-point)" "https://www.youtube.com/embed/OLDaaaaaaaa"

echo "All cameras healthy: nothing to do"
setup "[$CAM_A]"
echo "{\"items\":[$(video OLDaaaaaaaa 'Sea Point Live' live true UCvanilla)]}" > "$FIXTURES/videos.json"
echo '{"items":[]}' > "$FIXTURES/search.json"
run_case
expect "nothing changed" "$CHANGED" 0
expect "automerge not allowed" "$AUTOMERGE" false

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "All auto-repoint checks passed"
