#!/usr/bin/env bash
# Add the missing integrity check for the Rust toolchain download.
#
# WHY: ungoogled-chromium-macos' downloads-arm64.ini pins a sha512 for the llvm
# and nodejs downloads, but its [rust] section has NO hash at all. downloads.py
# treats hashes as optional and silently skips verification for entries without
# one — so the ~200 MB rust-nightly tarball goes into the compiler toolchain
# protected by nothing but TLS.
#
# This script closes that gap: it reads the Rust version from the ini, fetches
# the checksum Rust itself publishes for that exact file (static.rust-lang.org
# publishes a .sha256 next to every tarball), verifies the cached tarball if one
# exists, and writes the sha256 into the [rust] section so downloads.py verifies
# it on every future build. Because the hash is fetched per-version, the script
# keeps working after upstream bumps the Rust version.
#
# The ini lives inside the git-ignored build clone, so a fresh clone loses the
# fix — re-run this (like install-custom-patches.sh) after every re-clone.
#
# Idempotent: safe to re-run. Fails loudly on anything unexpected.
#
# Usage: scripts/pin-rust-hash.sh [path-to-clone]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONE="${1:-$HERE/ungoogled-chromium-macos}"
INI="$CLONE/downloads-arm64.ini"
CACHE="$CLONE/build/download_cache"

[ -f "$INI" ] || { echo "error: $INI not found (is the clone present?)" >&2; exit 1; }

VERSION="$(awk '/^\[rust\]/{f=1;next} /^\[/{f=0} f && /^version *= */{sub(/^version *= */,""); print; exit}' "$INI")"
[ -n "$VERSION" ] || { echo "error: no version in [rust] section of $INI" >&2; exit 1; }

URL="https://static.rust-lang.org/dist/$VERSION/rust-nightly-aarch64-apple-darwin.tar.xz.sha256"
echo "==> Fetching Rust's published checksum for $VERSION"
OFFICIAL="$(curl -fsSL "$URL" | awk '{print $1}')"
echo "$OFFICIAL" | grep -qE '^[0-9a-f]{64}$' \
  || { echo "error: response from $URL does not look like a sha256" >&2; exit 1; }
echo "    $OFFICIAL"

# If the tarball is already in the download cache, verify it right now rather
# than waiting for the next build to find out.
TARBALL="$CACHE/rust-nightly-$VERSION-aarch64-apple-darwin.tar.xz"
if [ -f "$TARBALL" ]; then
  LOCAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
  if [ "$LOCAL" = "$OFFICIAL" ]; then
    echo "==> Cached tarball verified OK"
  else
    echo "error: cached $TARBALL does NOT match Rust's published checksum!" >&2
    echo "       expected $OFFICIAL" >&2
    echo "       got      $LOCAL" >&2
    echo "       Delete the cached file and investigate before building." >&2
    exit 1
  fi
fi

python3 - "$INI" "$OFFICIAL" <<'PY'
import sys, pathlib, re
p, official = pathlib.Path(sys.argv[1]), sys.argv[2]
text = p.read_text()
m = re.search(r'(?ms)^\[rust\]\n(.*?)(?=^\[|\Z)', text)
assert m, "no [rust] section"
section = m.group(0)
existing = re.search(r'(?m)^sha256 *= *([0-9a-f]{64})$', section)
if existing:
    if existing.group(1) == official:
        print("already pinned -> " + official)
        sys.exit(0)
    new_section = section.replace(existing.group(0), "sha256 = " + official)
    print("re-pinned      -> " + official)
else:
    new_section = section.replace("[rust]\n", "[rust]\nsha256 = " + official + "\n", 1)
    print("pinned         -> " + official)
p.write_text(text.replace(section, new_section, 1))
PY
