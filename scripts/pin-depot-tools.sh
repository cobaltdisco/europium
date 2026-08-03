#!/usr/bin/env bash
# Pin depot_tools to a known-good commit inside the build clone.
#
# WHY: ungoogled-chromium's utils/clone.py fetches depot_tools from an unpinned
# `origin/main` and then applies utils/depot_tools.patch to it. depot_tools
# adopted ruff formatting on 2026-07-22 (commit 93974d014, "ruff: update
# formatting for the rest of the python files in depot_tools"), which rewrote
# single quotes to double quotes and re-wrapped lines across the tree. That
# breaks depot_tools.patch — 12 hunks across gclient.py / gclient_scm.py /
# gsutil.py are rejected — so EVERY ungoogled-chromium build fails, regardless
# of which Chromium version is being built.
#
# The fix is to pin depot_tools to the last commit before that reformat. This is
# also more correct than tracking main: a build of Chromium 150.0.7871.181 (cut
# 2026-07-21) should use the depot_tools of its own era, not a later one.
#
# Bump DEPOT_TOOLS_PIN when upstream refreshes depot_tools.patch for the
# ruff-formatted tree; at that point this script can be dropped entirely.
#
# Idempotent: safe to re-run. Fails loudly if clone.py no longer looks the way
# we expect, so an upstream change can never silently turn this into a no-op.
#
# Usage: scripts/pin-depot-tools.sh [path-to-clone]
set -euo pipefail

# Last depot_tools commit before the ruff reformat (Tue Jul 21 01:54:57 2026,
# "Roll recipe dependencies (trivial)"). Verified: depot_tools.patch applies
# cleanly here, all hunks, with only minor line offsets.
DEPOT_TOOLS_PIN="${DEPOT_TOOLS_PIN:-980d6af16e06ff993a52029019dc0628c0a0e1f0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONE="${1:-$HERE/ungoogled-chromium-macos}"
TARGET="$CLONE/ungoogled-chromium/utils/clone.py"

[ -f "$TARGET" ] || { echo "error: $TARGET not found (is the clone present?)" >&2; exit 1; }

UNPINNED="run(['git', 'fetch', '--depth=1', 'origin', 'main'], cwd=dtpath, check=True)"
PINNED="run(['git', 'fetch', '--depth=1', 'origin', '$DEPOT_TOOLS_PIN'], cwd=dtpath, check=True)"

if grep -qF "$PINNED" "$TARGET"; then
  echo "already pinned -> $DEPOT_TOOLS_PIN"
  exit 0
fi

# Any other pin (e.g. a stale one from a previous run) is rewritten to ours.
EXISTING="$(grep -oE "run\(\['git', 'fetch', '--depth=1', 'origin', '[0-9a-f]{40}'\], cwd=dtpath, check=True\)" "$TARGET" || true)"
if [ -n "$EXISTING" ]; then
  python3 - "$TARGET" "$EXISTING" "$PINNED" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
assert t.count(sys.argv[2]) == 1, "expected exactly one existing pin"
p.write_text(t.replace(sys.argv[2], sys.argv[3]))
PY
  echo "re-pinned      -> $DEPOT_TOOLS_PIN"
  exit 0
fi

n="$(grep -cF "$UNPINNED" "$TARGET" || true)"
[ "$n" = 1 ] || {
  echo "error: expected exactly 1 unpinned depot_tools fetch in clone.py, found $n." >&2
  echo "       Upstream changed clone.py — re-check by hand before trusting this script." >&2
  exit 1
}

python3 - "$TARGET" "$UNPINNED" "$PINNED" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(sys.argv[2], sys.argv[3], 1))
PY
echo "pinned         -> $DEPOT_TOOLS_PIN"
