#!/usr/bin/env bash
# Europium: check the right-click menus of the built app without a person
# looking at them.
#
# Starts the app with a throwaway profile, the context-menu-probe extension
# (which tries to add an item to every menu an extension can reach) and
# test/verify-page.html, then test/context-menu-check.swift opens each menu
# through the accessibility API and reads it. See that file for the checks.
#
# Unlike smoke-test.sh this needs a logged-in desktop: a browser window opens
# for about ten seconds and takes the focus. It also needs Accessibility
# permission for the app that runs this terminal (System Settings > Privacy &
# Security > Accessibility); the check says so if it is missing.
#
# Usage:
#   scripts/context-menu-test.sh [path/to/Europium.app]     # default: the build output
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${EUROPIUM_CLONE:-$HERE/ungoogled-chromium-macos}/build/src/out/Default/Europium.app}"
BIN="$APP/Contents/MacOS/Europium"
[ -x "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }

WORK="$(mktemp -d)"
APP_PID=""; WEB_PID=""
cleanup() {
  [ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true
  [ -z "$WEB_PID" ] || kill "$WEB_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Context menu test: $APP"
swiftc -O "$HERE/test/context-menu-check.swift" -o "$WORK/context-menu-check"

# Extensions get no menu items on file:// pages by default, so serve the page
# over http. Port 0 lets the OS pick a free port; the server writes it to a file.
python3 -c '
import functools, http.server, sys
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
handler = functools.partial(Quiet, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
open(sys.argv[2], "w").write(str(server.server_address[1]))
server.serve_forever()
' "$HERE/test" "$WORK/web.port" &
WEB_PID=$!
for _ in $(seq 1 40); do [ -s "$WORK/web.port" ] && break; sleep 0.25; done
[ -s "$WORK/web.port" ] || { echo "error: the local web server did not start" >&2; exit 1; }

# --force-renderer-accessibility makes the page content visible to the
# accessibility API from the start instead of only once a screen reader asks.
"$BIN" --user-data-dir="$WORK/profile" --no-first-run --no-default-browser-check \
  --force-renderer-accessibility --load-extension="$HERE/test/context-menu-probe" \
  "http://127.0.0.1:$(cat "$WORK/web.port")/verify-page.html" >"$WORK/app.log" 2>&1 &
APP_PID=$!

if "$WORK/context-menu-check" "$APP_PID"; then
  echo "==> Context menu test passed."
else
  echo "==> Context menu test FAILED." >&2
  exit 1
fi
