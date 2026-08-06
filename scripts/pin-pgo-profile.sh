#!/usr/bin/env bash
# Enable PGO using the profile Google publishes for our exact Chromium version.
#
# WHY: Chromium's official builds are profile-guided-optimized (PGO): Google
# records which code paths real browsing exercises most, and the compiler lays
# the binary out around that data (~5-10% on browser benchmarks). The profile
# for every Chromium version is published in a world-readable bucket, and
# ungoogled-chromium turns PGO off (chrome_pgo_phase=0 in flags.gn) only
# because its build never fetches from Google. We accept that one build-time
# fetch; the built browser itself still never talks to Google.
#
# What this does, all idempotent:
#   1. Reads our Chromium version from the clone, then fetches that version's
#      profile *name* from the Chromium source tree (chrome/build/mac-arm.pgo.txt).
#   2. Downloads the ~275 MB profile into build/download_cache (kept across
#      builds; the build tree itself gets wiped every build) and verifies it —
#      the file name embeds the SHA-1 of the file's own contents.
#   3. Flips chrome_pgo_phase 0->2 in the core flags.gn, and points
#      pgo_data_path at the cached profile via flags.macos.gn. With
#      pgo_data_path set, GN never runs Google's update_pgo_profiles.py.
#
# Like the other pin-* scripts this edits the git-ignored build clone, so
# re-run it after a fresh clone or a version upgrade (it then fetches the new
# version's profile automatically).
#
# Usage: scripts/pin-pgo-profile.sh [path-to-clone]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONE="${1:-$HERE/ungoogled-chromium-macos}"
CORE_FLAGS="$CLONE/ungoogled-chromium/flags.gn"
MAC_FLAGS="$CLONE/flags.macos.gn"
CACHE="$CLONE/build/download_cache"

[ -f "$CORE_FLAGS" ] || { echo "error: $CORE_FLAGS not found (is the clone present?)" >&2; exit 1; }
[ -f "$MAC_FLAGS" ]  || { echo "error: $MAC_FLAGS not found" >&2; exit 1; }

VERSION="$(cat "$CLONE/ungoogled-chromium/chromium_version.txt")"
echo "==> Chromium version: $VERSION"

# The name of the matching profile is recorded in the Chromium source tree
# itself. Fetch it straight from the version tag so this works even before the
# first clone of the source (gitiles serves file contents base64-encoded).
NAME="$(curl -fsSL "https://chromium.googlesource.com/chromium/src/+/refs/tags/$VERSION/chrome/build/mac-arm.pgo.txt?format=TEXT" | base64 -d | tr -d '[:space:]')"
case "$NAME" in
  chrome-mac-arm-*.profdata) ;;
  *) echo "error: unexpected profile name '$NAME'" >&2; exit 1 ;;
esac
echo "==> Profile: $NAME"

# Second dash-separated field from the end is the SHA-1 of the file contents
# (name layout: chrome-mac-arm-<branch>-<timestamp>-<sha1 of file>-<sha1>.profdata).
WANT_SHA1="$(echo "$NAME" | awk -F- '{print $(NF-1)}')"
echo "$WANT_SHA1" | grep -qE '^[0-9a-f]{40}$' \
  || { echo "error: cannot extract sha1 from profile name" >&2; exit 1; }

mkdir -p "$CACHE"
PROFILE="$CACHE/$NAME"
if [ ! -f "$PROFILE" ]; then
  echo "==> Downloading profile (~275 MB)"
  curl -fL --progress-bar -o "$PROFILE.part" \
    "https://storage.googleapis.com/chromium-optimization-profiles/pgo_profiles/$NAME"
  mv "$PROFILE.part" "$PROFILE"
fi

GOT_SHA1="$(shasum -a 1 "$PROFILE" | awk '{print $1}')"
if [ "$GOT_SHA1" != "$WANT_SHA1" ]; then
  echo "error: $PROFILE does not match the checksum in its name!" >&2
  echo "       expected $WANT_SHA1" >&2
  echo "       got      $GOT_SHA1" >&2
  echo "       Delete the file and investigate before building." >&2
  exit 1
fi
echo "==> Profile verified OK"

# Old profiles from previous versions serve no purpose; keep the cache tidy.
for old in "$CACHE"/chrome-mac-arm-*.profdata; do
  [ -e "$old" ] && [ "$old" != "$PROFILE" ] && rm -f "$old" && echo "==> Removed stale $(basename "$old")"
done

# 1/2: chrome_pgo_phase 0 -> 2 in the core flags.
if grep -qxF 'chrome_pgo_phase=2' "$CORE_FLAGS"; then
  echo "==> chrome_pgo_phase already 2"
elif grep -qxF 'chrome_pgo_phase=0' "$CORE_FLAGS"; then
  /usr/bin/sed -i '' 's/^chrome_pgo_phase=0$/chrome_pgo_phase=2/' "$CORE_FLAGS"
  echo "==> chrome_pgo_phase 0 -> 2"
else
  echo "error: no chrome_pgo_phase line in $CORE_FLAGS — upstream changed it, re-check by hand" >&2
  exit 1
fi

# 2/2: point the build at the cached profile (absolute path; GN rebases it).
LINE="pgo_data_path=\"$PROFILE\""
if grep -qxF "$LINE" "$MAC_FLAGS"; then
  echo "==> pgo_data_path already set"
elif grep -q '^pgo_data_path=' "$MAC_FLAGS"; then
  python3 - "$MAC_FLAGS" "$LINE" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
p.write_text(re.sub(r'(?m)^pgo_data_path=.*$', sys.argv[2], p.read_text(), count=1))
PY
  echo "==> pgo_data_path updated"
else
  [ -z "$(tail -c1 "$MAC_FLAGS")" ] || echo >> "$MAC_FLAGS"
  printf '%s\n' "$LINE" >> "$MAC_FLAGS"
  echo "==> pgo_data_path added"
fi
echo "done."
