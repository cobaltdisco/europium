#!/usr/bin/env bash
# Point the Homebrew tap at a new Europium release.
#
# Run this AFTER `gh release create` has published the .dmg — it verifies the
# release asset is actually reachable before touching the cask, so users never
# see a cask whose url 404s.
#
# Usage:
#   scripts/update-tap.sh                      # newest dmg in the build dir, tap at ../homebrew-europium
#   scripts/update-tap.sh <dmg> <tap-dir>
#
# Env: EUROPIUM_TAP (tap checkout), EUROPIUM_REPO (owner/name for the release check)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP="${2:-${EUROPIUM_TAP:-$(cd "$HERE/.." && pwd)/homebrew-europium}}"
REPO="${EUROPIUM_REPO:-cobaltdisco/europium}"
CASK="$TAP/Casks/europium.rb"

DMG="${1:-}"
if [ -z "$DMG" ]; then
  DMG="$(ls -t "$HERE"/ungoogled-chromium-macos/build/europium_*_macos.dmg 2>/dev/null | head -1 || true)"
fi
[ -n "$DMG" ] && [ -f "$DMG" ] || { echo "error: no .dmg found (pass one explicitly)" >&2; exit 1; }
[ -f "$CASK" ] || { echo "error: cask not found at $CASK" >&2; exit 1; }

BASE="$(basename "$DMG")"
# europium_<version>_macos.dmg  ->  <version>
VERSION="${BASE#europium_}"; VERSION="${VERSION%_macos.dmg}"
[ "$VERSION" != "$BASE" ] || { echo "error: cannot parse version from $BASE" >&2; exit 1; }

echo "==> dmg     : $BASE"
echo "==> version : $VERSION"

# The .dmg must be notarized+stapled, or downloaders get a Gatekeeper prompt.
echo "==> Checking the disk image is notarized"
xcrun stapler validate "$DMG" >/dev/null 2>&1 \
  || { echo "error: $BASE has no stapled notarization ticket — run sign-and-package.sh --dmg first" >&2; exit 1; }
spctl -a -t open --context context:primary-signature "$DMG" >/dev/null 2>&1 \
  || { echo "error: $BASE is rejected by Gatekeeper" >&2; exit 1; }

echo "==> Checking the release asset is published"
if command -v gh >/dev/null 2>&1; then
  gh release view "$VERSION" --repo "$REPO" --json assets \
     --jq '.assets[].name' 2>/dev/null | grep -qxF "$BASE" \
    || { echo "error: $BASE is not attached to release $VERSION of $REPO. Publish it first:" >&2
         echo "       gh release create $VERSION \"$DMG\" --repo $REPO" >&2; exit 1; }
  echo "    release $VERSION has $BASE"
else
  echo "    (gh not installed — skipping release check)"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "==> sha256  : $SHA"

OLD_VERSION="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$CASK")"
if [ "$OLD_VERSION" = "$VERSION" ]; then
  echo "==> Cask already at $VERSION; updating sha256 only if it changed"
fi

# Rewrite just the two lines; everything else in the cask is hand-maintained.
/usr/bin/sed -i '' \
  -e "s|^  version \".*\"$|  version \"$VERSION\"|" \
  -e "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" \
  "$CASK"

if git -C "$TAP" diff --quiet -- "$CASK"; then
  echo "==> Cask already up to date, nothing to commit."
  exit 0
fi

git -C "$TAP" --no-pager diff -- "$CASK" | sed 's/^/    /'
git -C "$TAP" add "$CASK"
git -C "$TAP" commit -q -m "europium ${VERSION}

Built from ${REPO} release ${VERSION}; dmg notarized and stapled, sha256 verified
against the published release asset."
git -C "$TAP" push -q origin HEAD
echo "==> Pushed. Users get it with: brew upgrade --cask europium"

if command -v brew >/dev/null 2>&1; then
  echo "==> brew audit"
  brew audit --cask --online cobaltdisco/europium/europium || \
    echo "    (audit reported problems — fix before announcing)"
fi
