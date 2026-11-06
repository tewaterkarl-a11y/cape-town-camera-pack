#!/usr/bin/env bash
# Tests for scripts/check.sh, with the network faked.
#
# The point: an empty report only means "healthy" when the cameras were
# actually checked. check.sh writes "checked" or "not checked: <reason>" to
# $STATUS_FILE, and the watcher fails its run after three skipped checks in a
# row. From 15 October to 6 November 2026 the watcher logged nothing useful
# while its runs stayed green; these cases pin the signal that prevents a
# repeat. Run locally or in CI: bash scripts/test-check.sh (needs jq).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILURES=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake curl. The site and apex always answer; the Data API answers from
# $FIXTURES/videos.json, or fails when that file is missing; YouTube itself
# (the no-key fallback) always fails, as it does from CI runners.
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  https://www.capetownwindow.com) echo "<title>Cape Town Window</title>" ;;
  https://capetownwindow.com) echo "https://www.capetownwindow.com/" ;;
  *googleapis.com/youtube/v3/videos*)
    if [ -f "$FIXTURES/videos.json" ]; then cat "$FIXTURES/videos.json"; else exit 22; fi ;;
  *) exit 22 ;;
esac
FAKE
chmod +x "$WORK/bin/curl"
# check.sh sleeps before retries on the fallback path; skip the waits.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/sleep"

cat > "$WORK/cameras.json" <<'JSON'
{"cameras":[
  {"id":"a","name":"Camera A","type":"youtube","streamUrl":"https://www.youtube.com/embed/AAAAAAAAAAA","enabled":true},
  {"id":"b","name":"Camera B","type":"youtube","streamUrl":"https://www.youtube.com/embed/BBBBBBBBBBB","enabled":true}
]}
JSON

video() { # id state [actualEndTime]
  local end="${3:-}"
  printf '{"id":"%s","snippet":{"title":"Cam %s","liveBroadcastContent":"%s"},"status":{"embeddable":true},"liveStreamingDetails":%s}' \
    "$1" "$1" "$2" "$( [ -n "$end" ] && printf '{"actualEndTime":"%s"}' "$end" || echo '{}')"
}

run_check() { # key
  (cd "$WORK" && FIXTURES="$WORK/fx" PATH="$WORK/bin:$PATH" YT_API_KEY="$1" \
    REPORT_FILE="$WORK/report.txt" STATUS_FILE="$WORK/status.txt" bash "$ROOT/scripts/check.sh" 2>/dev/null)
  RC=$?
  STATUS=$(cat "$WORK/status.txt")
  PROBLEMS=$(wc -l < "$WORK/report.txt" | tr -d ' ')
}

expect() { # description actual expected
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected '$3', got '$2'"; FAILURES=$((FAILURES + 1)); fi
}

echo "Case 1: every camera live"
rm -rf "$WORK/fx"; mkdir -p "$WORK/fx"
echo "{\"items\":[$(video AAAAAAAAAAA live),$(video BBBBBBBBBBB live)]}" > "$WORK/fx/videos.json"
run_check test
expect "exit code" "$RC" 0
expect "status" "$STATUS" "checked"
expect "problems" "$PROBLEMS" 0

echo "Case 2: one stream ended (the 5 to 6 November situation)"
echo "{\"items\":[$(video AAAAAAAAAAA live 2026-11-05T20:00:00Z),$(video BBBBBBBBBBB live)]}" > "$WORK/fx/videos.json"
run_check test
expect "status" "$STATUS" "checked"
expect "problems" "$PROBLEMS" 1
expect "reported as not live" "$(grep -c '^CAMERA NOT LIVE: Camera A' "$WORK/report.txt")" 1

echo "Case 3: Data API call fails (outage, spent quota, bad key)"
rm -f "$WORK/fx/videos.json"
run_check test
expect "exit code" "$RC" 0
expect "status says not checked" "${STATUS%%:*}" "not checked"
expect "no problems reported (so status is the only signal)" "$PROBLEMS" 0

echo "Case 4: no API key, and YouTube blocks the fallback"
run_check ""
expect "status says not checked" "${STATUS%%:*}" "not checked"
expect "no problems reported" "$PROBLEMS" 0

echo "Case 5: no STATUS_FILE given (the monitor's call) still works"
echo "{\"items\":[$(video AAAAAAAAAAA live),$(video BBBBBBBBBBB live)]}" > "$WORK/fx/videos.json"
(cd "$WORK" && FIXTURES="$WORK/fx" PATH="$WORK/bin:$PATH" YT_API_KEY=test REPORT_FILE="$WORK/report.txt" \
  bash "$ROOT/scripts/check.sh" 2>/dev/null)
expect "exit code" "$?" 0

if [ "$FAILURES" -gt 0 ]; then echo "$FAILURES check(s) failed."; exit 1; fi
echo "All check.sh cases passed."
