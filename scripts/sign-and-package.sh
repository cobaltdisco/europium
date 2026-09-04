#!/usr/bin/env bash
# Europium: code signing / notarization / .dmg packaging.
#
# Adapted from ungoogled-chromium-macos' sign_and_package_app.sh, which hardcodes
# "Chromium.app" / "Chromium Framework" paths and ungoogled bundle identifiers —
# all of which broke when we rebranded to Europium.
#
# SECRETS: this script never accepts or stores a password. Store notarization
# credentials once, yourself:
#   xcrun notarytool store-credentials "europium-notary" \
#     --apple-id "<your Apple ID>" --team-id "Z48W7TAXR4" --password "<app-specific password>"
#
# Usage:
#   scripts/sign-and-package.sh              # sign only (default)
#   scripts/sign-and-package.sh --install    # sign + copy to /Applications
#   scripts/sign-and-package.sh --notarize   # sign + notarize + staple
#   scripts/sign-and-package.sh --dmg        # sign + notarize + staple + .dmg
# Flags combine, e.g. --notarize --install
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONE="${EUROPIUM_CLONE:-$HERE/ungoogled-chromium-macos}"
SRC="$CLONE/build/src"
OUT="$SRC/out/Default"
APP="$OUT/Europium.app"
FW="$APP/Contents/Frameworks/Europium Framework.framework"
ENT="$CLONE/entitlements"
BUNDLE_ID="com.fx.europium"

# Two Developer ID certs share the same common name, so signing by name is ambiguous.
# Default to the SHA-1 of the newer one; override with EUROPIUM_CODESIGN_ID.
CODESIGN_ID="${EUROPIUM_CODESIGN_ID:-F6177CCA4D281EB1BE7A01CBC3E6BFF67A899642}"
NOTARY_PROFILE="${EUROPIUM_NOTARY_PROFILE:-europium-notary}"

DO_NOTARIZE=0; DO_DMG=0; DO_INSTALL=0
for a in "$@"; do
  case "$a" in
    --notarize) DO_NOTARIZE=1 ;;
    --dmg)      DO_NOTARIZE=1; DO_DMG=1 ;;
    --install)  DO_INSTALL=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

[ -d "$APP" ] || { echo "error: $APP not found (build first)" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$CODESIGN_ID" \
  || { echo "error: signing identity $CODESIGN_ID not found in keychain" >&2; exit 1; }
# Preflight the notary credential BEFORE signing anything: the keychain item
# has vanished twice (2026-08-29, 2026-09-04) and discovering that only after
# ten minutes of codesign work wastes the whole run.
if [ "$DO_NOTARIZE" = 1 ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "error: keychain profile '$NOTARY_PROFILE' not found (nothing signed yet). Run 'xcrun notarytool store-credentials' first (see header)." >&2; exit 1; }
fi

sign() {  # sign <identifier> <target> [extra codesign args...]
  local id="$1" target="$2"; shift 2
  codesign --sign "$CODESIGN_ID" --force --timestamp --identifier "$id" "$@" "$target"
}

# notarize <file>: submit, then poll ourselves. `notarytool submit --wait` gives
# up on a single transient HTTP timeout (2026-09-04: Apple had already Accepted
# the dmg, the wait just lost the connection), which failed the whole run.
notarize() {
  local file="$1" id status
  id="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --output-format json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  echo "    submission $id"
  for _ in $(seq 1 120); do   # up to ~60 min
    status="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null \
              | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
    case "$status" in
      Accepted) echo "    status: Accepted"; return 0 ;;
      Invalid|Rejected)
        echo "    status: $status — Apple's per-file findings:" >&2
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        return 1 ;;
      *) sleep 30 ;;   # "In Progress", or an empty status from a transient API error — keep polling
    esac
  done
  echo "error: notarization of $file not finished after 60 min (submission $id)" >&2
  return 1
}

echo "==> Clearing extended attributes (avoids the incoming-connection prompt, uc-macos issue #17)"
xattr -cs "$APP"

echo "==> Signing inner components (inside-out)"
H="$FW/Helpers"
L="$FW/Libraries"
sign chrome_crashpad_handler          "$H/chrome_crashpad_handler"        --options=restrict,library,runtime,kill
sign "$BUNDLE_ID.helper"              "$H/Europium Helper.app"            --options restrict,library,runtime,kill
sign "$BUNDLE_ID.helper.renderer"     "$H/Europium Helper (Renderer).app" --options restrict,kill,runtime --entitlements "$ENT/helper-renderer-entitlements.plist"
sign "$BUNDLE_ID.helper"              "$H/Europium Helper (GPU).app"      --options restrict,kill,runtime --entitlements "$ENT/helper-gpu-entitlements.plist"
sign "$BUNDLE_ID.framework.AlertNotificationService" \
                                      "$H/Europium Helper (Alerts).app"   --options restrict,library,runtime,kill
sign app_mode_loader                  "$H/app_mode_loader"                --options restrict,library,runtime,kill
sign web_app_shortcut_copier          "$H/web_app_shortcut_copier"        --options restrict,library,runtime,kill
# Sign every dylib present rather than a fixed list — Chromium adds libraries
# over time (151 brought libvulkan.dylib; notarization rejects any unsigned one).
for dylib in "$L"/*.dylib; do
  sign "$(basename "$dylib" .dylib)" "$dylib"
done

echo "==> Signing framework"
sign "$BUNDLE_ID.framework" "$FW"

echo "==> Signing outer app"
codesign --sign "$CODESIGN_ID" --force --timestamp --identifier "$BUNDLE_ID" \
  --options restrict,library,runtime,kill \
  --entitlements "$ENT/app-entitlements.plist" \
  --requirements "=designated => identifier \"$BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */" \
  "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || echo "   (spctl will only pass once the app is notarized)"

if [ "$DO_NOTARIZE" = 1 ]; then
  echo "==> Notarizing (profile: $NOTARY_PROFILE)"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "error: keychain profile '$NOTARY_PROFILE' not found. Run 'xcrun notarytool store-credentials' first (see header)." >&2; exit 1; }
  ZIP="$OUT/notarize.zip"; rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  echo "==> Gatekeeper assessment after notarization:"
  spctl --assess --type execute --verbose=4 "$APP"
fi

if [ "$DO_INSTALL" = 1 ]; then
  DEST="/Applications/Europium.app"
  echo "==> Installing to $DEST"
  if pgrep -f "$DEST/Contents/MacOS/Europium" >/dev/null 2>&1; then
    echo "    quitting the running copy first"
    pkill -f "$DEST/Contents/MacOS/Europium" || true
    sleep 2
  fi
  rm -rf "$DEST"                 # replace wholesale so no stale files survive
  ditto "$APP" "$DEST"           # ditto preserves xattrs / signature structure
  codesign --verify --deep --strict "$DEST" && echo "    signature valid at $DEST"
fi

if [ "$DO_DMG" = 1 ]; then
  V="$(cat "$CLONE/ungoogled-chromium/chromium_version.txt")"   # upstream Chromium
  UR="$(cat "$CLONE/ungoogled-chromium/revision.txt")"          # ungoogled revision
  PR="$(cat "$CLONE/revision.txt")"                             # macOS packaging revision
  # Our own revision: lets us ship a new build when only OUR patches changed and
  # the three upstream components are unchanged (otherwise there'd be no version
  # to bump and `brew upgrade` users would never see the update).
  ER="${EUROPIUM_REVISION:-1}"
  DMG="$CLONE/build/europium_${V}-${UR}.${PR}.${ER}_macos.dmg"
  echo "==> Packaging $DMG"
  rm -f "$DMG"
  ( cd "$SRC" && chrome/installer/mac/pkg-dmg \
      --sourcefile --source "$APP" --target "$DMG" \
      --volname Europium --symlink /Applications:/Applications \
      --format UDBZ --verbosity 2 )

  # The .app inside is already notarized+stapled, but the disk image itself must
  # also be signed and notarized or Gatekeeper rejects it on download.
  echo "==> Signing the disk image"
  codesign --sign "$CODESIGN_ID" --force --timestamp "$DMG"
  echo "==> Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "==> Disk image assessment (as a downloader would see it):"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  echo "    -> $DMG"
fi

echo "==> Done."
