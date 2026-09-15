#!/usr/bin/env bash
# Install this project's custom patches into the ungoogled-chromium-macos clone.
#
# The build clone (ungoogled-chromium-macos/) is git-ignored, so the canonical
# patches live here in patches/ and are copied in + registered in the clone's
# patches/series by this script. Idempotent: safe to re-run after an upgrade or
# a fresh clone.
#
# Also installs patches/shell-overrides/*.patch OVER the shell's own copies in
# patches/ungoogled-chromium/macos/. WHY: when the ungoogled core repo tags a
# Chromium version before the macOS shell catches up, one of the 8 kept shell
# patches can stop applying; the override is our rebase of that exact patch,
# kept here (versioned) instead of as a loose edit inside the gitignored clone.
# Each override must name an existing shell patch AND carry a '# base-sha256:'
# header naming the upstream copy it replaces; the installer accepts only that
# exact upstream content (install) or the override itself (idempotent re-run)
# and hard-errors on anything else, so an upstream rename, drop, or edit of the
# original is noticed immediately instead of being silently overwritten.
# Delete an override as soon as the upstream shell ships its own rebase.
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
SHELL_PATCH_DIR="$CLONE/patches/ungoogled-chromium/macos"
for o in "$HERE"/patches/shell-overrides/*.patch; do
  [ -e "$o" ] || break
  name="$(basename "$o")"
  target="$SHELL_PATCH_DIR/$name"
  [ -f "$target" ] || { echo "error: shell override $name has no counterpart at $target — upstream renamed/dropped it; delete or rename the override" >&2; exit 1; }
  grep -qx "ungoogled-chromium/macos/$name" "$SERIES" || { echo "error: $name is not in $SERIES" >&2; exit 1; }
  expected="$(sed -n 's/^# base-sha256: \([0-9a-f]\{64\}\)$/\1/p' "$o" | head -1)"
  [ -n "$expected" ] || { echo "error: $name lacks a '# base-sha256: <hash>' header line" >&2; exit 1; }
  actual="$(shasum -a 256 "$target" | cut -d' ' -f1)"
  if cmp -s "$o" "$target"; then
    echo "override: already installed -> ungoogled-chromium/macos/$name"
  elif [ "$actual" = "$expected" ]; then
    cp "$o" "$target"
    echo "override: installed        -> ungoogled-chromium/macos/$name (replaces upstream shell copy $expected)"
  else
    echo "error: $target is neither the override nor its recorded upstream base ($expected);" >&2
    echo "       upstream changed this patch (actual $actual) — re-review the override, then update or delete it" >&2
    exit 1
  fi
done
echo "done."
