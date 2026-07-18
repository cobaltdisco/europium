#!/usr/bin/env bash
# Install this project's custom patches into the ungoogled-chromium-macos clone.
#
# The build clone (ungoogled-chromium-macos/) is git-ignored, so the canonical
# patches live here in patches/ and are copied in + registered in the clone's
# patches/series by this script. Idempotent: safe to re-run after an upgrade or
# a fresh clone.
#
# Usage: scripts/install-custom-patches.sh [path-to-clone]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONE="${1:-$HERE/ungoogled-chromium-macos}"
DEST_SUBDIR="custom"                       # series entries live under patches/custom/
SERIES="$CLONE/patches/series"

[ -f "$SERIES" ] || { echo "error: series not found at $SERIES (is the clone present?)" >&2; exit 1; }
mkdir -p "$CLONE/patches/$DEST_SUBDIR"

for p in "$HERE"/patches/*.patch; do
  [ -e "$p" ] || { echo "no patches in $HERE/patches"; break; }
  name="$(basename "$p")"
  entry="$DEST_SUBDIR/$name"
  cp "$p" "$CLONE/patches/$DEST_SUBDIR/$name"
  if grep -qxF "$entry" "$SERIES"; then
    echo "series: already present  -> $entry"
  else
    # guard: if series lacks a trailing newline, add one so we don't fuse onto the last line
    [ -z "$(tail -c1 "$SERIES")" ] || echo >> "$SERIES"
    printf '%s\n' "$entry" >> "$SERIES"
    echo "series: added            -> $entry"
  fi
done
echo "done."
