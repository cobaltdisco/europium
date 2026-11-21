#!/usr/bin/env bash
# Europium: start the built app and check that it actually works.
#
# The build checks only look at the binary (version string, strings, source).
# A build that crashes on launch, or one where Manifest V2 extensions quietly
# stopped working, would pass all of them. This starts the app headless with a
# throwaway profile (no window, nothing touches a real profile) and checks:
#   1. it starts and reports the expected version;
#   2. the GPU process is running;
#   3. the MV2 probe extension's background page is running;
#   4. a page loads and runs script, and the probe's blocking webRequest
#      listener cancels the one request it should (test/smoke/index.html).
#
# Usage:
#   scripts/smoke-test.sh [path/to/Europium.app]     # default: the build output
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${EUROPIUM_CLONE:-$HERE/ungoogled-chromium-macos}/build/src/out/Default/Europium.app}"
BIN="$APP/Contents/MacOS/Europium"
[ -x "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }
WANT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

WORK="$(mktemp -d)"
APP_PID=""; WEB_PID=""
cleanup() {
  [ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true
  [ -z "$WEB_PID" ] || kill "$WEB_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "smoke test FAILED: $*" >&2
  if [ -s "$WORK/app.log" ]; then echo "--- last lines of the app log:" >&2; tail -20 "$WORK/app.log" >&2; fi
  exit 1
}

# wait_for <seconds> <description> <command...>: poll until the command succeeds.
wait_for() {
  local secs="$1" what="$2"; shift 2
  for _ in $(seq 1 $((secs * 4))); do
    "$@" && return 0
    [ -z "$APP_PID" ] || kill -0 "$APP_PID" 2>/dev/null || fail "the app exited while waiting for $what"
    sleep 0.25
  done
  fail "timed out after ${secs}s waiting for $what"
}

echo "==> Smoke test: $APP ($WANT)"

# The page must come from http://, because webRequest does not see file://.
# Port 0 lets the OS pick a free port; the server writes it to a file.
python3 -c '
import functools, http.server, sys
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
handler = functools.partial(Quiet, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
open(sys.argv[2], "w").write(str(server.server_address[1]))
server.serve_forever()
' "$HERE/test/smoke" "$WORK/web.port" &
WEB_PID=$!
wait_for 10 "the local web server" test -s "$WORK/web.port"
PAGE="http://127.0.0.1:$(cat "$WORK/web.port")/index.html"

"$BIN" --headless=new --user-data-dir="$WORK/profile" --remote-debugging-port=0 \
  --no-first-run --load-extension="$HERE/test/mv2-probe" about:blank >"$WORK/app.log" 2>&1 &
APP_PID=$!
wait_for 30 "the debugging port" test -s "$WORK/profile/DevToolsActivePort"
CDP="http://127.0.0.1:$(head -1 "$WORK/profile/DevToolsActivePort")"

# Every request to the browser is time-limited: a browser that opens its
# debugging port and then hangs must fail the test, not stall a release run.
cdp() { curl -fsS --connect-timeout 2 --max-time 5 "$@"; }

# targets: one "type<TAB>title" line per debugging target.
targets() {
  cdp "$CDP/json/list" 2>/dev/null | python3 -c '
import json, sys
for t in json.load(sys.stdin):
    print(t["type"] + "\t" + t["title"])' 2>/dev/null
}
has_target() { targets | grep -qF "$1"; }

got="$(cdp "$CDP/json/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Browser"])')"
[ "$got" = "Chrome/$WANT" ] || fail "the running browser reports '$got', expected 'Chrome/$WANT'"
echo "    started, reports $got"

gpu_running() { pgrep -P "$APP_PID" -f -- '--type=gpu-process' >/dev/null; }
wait_for 15 "the GPU process" gpu_running
echo "    GPU process is running"

wait_for 20 "the MV2 probe's background page" has_target "$(printf 'background_page\tMV2 Probe')"
echo "    MV2 extension loaded, background page is running"

cdp -X PUT "$CDP/json/new?$PAGE" >/dev/null || fail "could not open $PAGE"
page_done() { targets | grep -F "$(printf 'page\tsmoke: ')" | grep -qv 'smoke: running'; }
wait_for 20 "the test page to finish" page_done
title="$(targets | sed -n 's/^page	\(smoke: .*\)$/\1/p' | head -1)"
[ "$title" = "smoke: blockme=blocked allowed=loaded" ] \
  || fail "the test page reports '$title', expected 'smoke: blockme=blocked allowed=loaded'"
echo "    page loaded and ran script; MV2 blocking webRequest works"

kill -0 "$APP_PID" 2>/dev/null || fail "the app exited before the end of the test"
echo "==> Smoke test passed."
