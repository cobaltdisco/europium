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
TEAM_ID="${EUROPIUM_TEAM_ID:-Z48W7TAXR4}"   # only used to verify every helper carries our signature

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

# macOS records privacy permissions such as Local Network access under the
# CFBundleIdentifier, but checks them against the code signing identifier; if
# the two differ the permission never takes effect (uc-macos issue #361).
# BUNDLE_ID is hardcoded above and MAC_BUNDLE_ID lives in rebrand-europium.patch,
# so refuse to sign when they have drifted apart.
plist_bundle_id() {  # plist_bundle_id <Info.plist>
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1"
}
_app_bid="$(plist_bundle_id "$APP/Contents/Info.plist")"
[ "$_app_bid" = "$BUNDLE_ID" ] \
  || { echo "error: Europium.app's CFBundleIdentifier is $_app_bid, but this script signs as $BUNDLE_ID" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$CODESIGN_ID" \
  || { echo "error: signing identity $CODESIGN_ID not found in keychain" >&2; exit 1; }
screen_locked() {
  ioreg -n Root -d1 -a | grep -q CGSSessionScreenIsLocked
}

# The notary profile lives in the data-protection keychain as a
# when-unlocked item, so while the screen is locked secd refuses it
# (-25308, "keychain is locked") and notarytool misreports that as
# "No Keychain password item found". That — not a deleted credential — is
# what the four "vanished" credentials (08-29, 09-04, 09-19, 09-27) were:
# every one was a run started right after an unattended build, and the
# 09-27 one is in the unified log. So wait for an unlock instead of failing,
# and only call the profile missing when the screen is unlocked.
require_notary_profile() {
  if screen_locked; then
    echo "==> Screen is locked; the notary credential is unreadable until it is unlocked. Waiting..."
    while screen_locked; do sleep 30; done
    echo "==> Unlocked, continuing."
  fi
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "error: keychain profile '$NOTARY_PROFILE' not found with the screen unlocked. Run 'xcrun notarytool store-credentials' first (see header)." >&2; exit 1; }
}

# Preflight the notary credential BEFORE signing anything: discovering a
# problem only after ten minutes of codesign work wastes the whole run.
if [ "$DO_NOTARIZE" = 1 ]; then
  require_notary_profile
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
  require_notary_profile   # the screen may have locked since the preflight
  id="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --output-format json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  echo "    submission $id"
  for _ in $(seq 1 120); do   # up to ~60 min of unlocked polling
    while screen_locked; do sleep 30; done   # credential unreadable; don't burn attempts
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

# package_dmg <app> <dmg>: build the disk image users download.
#
# Chromium's pkg-dmg builds the image with `hdiutil makehybrid -hfs`, which
# stamps Finder information on every file. The copy a user drags out of the
# image then fails `codesign --verify --strict` ("resource fork, Finder
# information, or similar detritus not allowed"), although Gatekeeper accepts
# it. Every release from 150 through 158.0.8127.36 shipped that way.
# `diskutil image create from` writes no such attributes. It produces an APFS
# image; ULMO (lzma) is about 17% smaller than the bzip2 image it replaces and
# mounts on macOS 10.15+, older than anything Chromium still supports.
package_dmg() {
  local app="$1" dmg="$2" rc=0
  _dmg_stage="$(mktemp -d "$(dirname "$dmg")/dmg-stage.XXXXXX")"
  ditto "$app" "$_dmg_stage/Europium.app" \
    && ln -s /Applications "$_dmg_stage/Applications" \
    && rm -f "$dmg" \
    && diskutil image create from --format ULMO --volumeName Europium "$_dmg_stage" "$dmg" \
    || rc=$?
  rm -rf "$_dmg_stage"; _dmg_stage=""
  return "$rc"
}

# eject_image <mount point>: detach a mounted image, retrying while something
# (Spotlight, a virus scanner) still holds the volume busy.
eject_image() {
  local mp="$1"
  for _ in 1 2 3 4 5; do
    if diskutil eject "$mp" >/dev/null 2>&1; then
      rmdir "$mp" 2>/dev/null || true
      return 0
    fi
    sleep 2
  done
  echo "warning: the disk image at $mp is still mounted; eject it with: diskutil eject '$mp'" >&2
  return 1
}

# The staging copy is ~500 MB and the verification mount is invisible in
# Finder, so neither may outlive the script, including on Ctrl-C or an error.
_dmg_stage=""; _dmg_mount=""
dmg_cleanup() {
  if [ -n "$_dmg_mount" ]; then eject_image "$_dmg_mount" || true; _dmg_mount=""; fi
  if [ -n "$_dmg_stage" ]; then rm -rf "$_dmg_stage"; _dmg_stage=""; fi
}
trap dmg_cleanup EXIT

# verify_dmg <dmg> <version>: check the app inside the image, which is the copy
# users actually install. The checks earlier in this script only ever saw the
# build directory, which is how the pkg-dmg problem above went unnoticed.
verify_dmg() {
  local dmg="$1" want="$2" mp app got rc=0
  mp="$(mktemp -d)"
  diskutil image attach --readOnly --nobrowse --mountPoint "$mp" "$dmg" >/dev/null \
    || { rmdir "$mp"; echo "error: cannot mount $dmg" >&2; return 1; }
  _dmg_mount="$mp"
  app="$mp/Europium.app"
  codesign --verify --deep --strict "$app" \
    || { echo "error: the app inside the disk image fails strict signature verification" >&2; rc=1; }
  spctl --assess --type execute "$app" \
    || { echo "error: Gatekeeper rejects the app inside the disk image" >&2; rc=1; }
  xcrun stapler validate -q "$app" \
    || { echo "error: the app inside the disk image has no valid notarization ticket" >&2; rc=1; }
  got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ "$got" = "$want" ] \
    || { echo "error: the app inside the disk image is version '$got', expected '$want'" >&2; rc=1; }
  [ "$(readlink "$mp/Applications" 2>/dev/null)" = /Applications ] \
    || { echo "error: the disk image has no Applications shortcut" >&2; rc=1; }
  eject_image "$mp" || true   # a stuck mount is reported, but says nothing about the image
  _dmg_mount=""
  return "$rc"
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
# Chromium 153 added the "Aperitif" helper family (chrome/BUILD.gn
# content_mac_aperitif_helpers): same identifiers / options / entitlements as
# their classic counterparts, per chrome/installer/mac/signing/parts.py.
sign "$BUNDLE_ID.helper"              "$H/Europium Helper (Aperitif).app"          --options restrict,library,runtime,kill
sign "$BUNDLE_ID.helper.renderer"     "$H/Europium Helper (Aperitif Renderer).app" --options restrict,kill,runtime --entitlements "$ENT/helper-renderer-entitlements.plist"
sign "$BUNDLE_ID.helper"              "$H/Europium Helper (Aperitif GPU).app"      --options restrict,kill,runtime --entitlements "$ENT/helper-gpu-entitlements.plist"
sign "$BUNDLE_ID.framework.AlertNotificationService" \
                                      "$H/Europium Helper (Aperitif Alerts).app"   --options restrict,library,runtime,kill
sign app_mode_loader                  "$H/app_mode_loader"                --options restrict,library,runtime,kill
sign web_app_shortcut_copier          "$H/web_app_shortcut_copier"        --options restrict,library,runtime,kill
# Sign every dylib present rather than a fixed list — Chromium adds libraries
# over time (151 brought libvulkan.dylib; notarization rejects any unsigned one).
for dylib in "$L"/*.dylib; do
  sign "$(basename "$dylib" .dylib)" "$dylib"
done

# Guard: every helper bundle must now carry our Developer ID signature. A new
# helper Chromium adds later would otherwise stay ad-hoc and only surface as a
# cryptic "code has no resources" error from codesign --verify (153 lesson).
# (capture first: with pipefail, `codesign | grep -q` fails spuriously when
# grep exits early and codesign takes SIGPIPE)
for helper in "$H"/*.app; do
  _sig="$(codesign -dv "$helper" 2>&1 || true)"
  case "$_sig" in *"TeamIdentifier=$TEAM_ID"*) ;; *)
    echo "error: $(basename "$helper") is not signed with team $TEAM_ID — add it to the helper list above" >&2; exit 1 ;;
  esac
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

# Every bundle must be signed with its own CFBundleIdentifier (see #361 above).
# A helper Chromium adds or renames later would otherwise be signed with a
# stale identifier from the list above and silently break its permissions.
verify_identifier() {  # verify_identifier <bundle> <Info.plist>
  local bundle="$1" bid sid sig
  # PlistBuddy prints its errors to stdout, so check the exit status explicitly
  # (set -e does not apply inside a function called from `||`).
  if ! bid="$(plist_bundle_id "$2" 2>/dev/null)" || [ -z "$bid" ]; then
    echo "error: cannot read CFBundleIdentifier from $2" >&2
    return 1
  fi
  sig="$(codesign -dv "$bundle" 2>&1 || true)"   # capture first (pipefail + SIGPIPE, see above)
  sid="$(printf '%s\n' "$sig" | sed -n 's/^Identifier=//p')"
  if [ "$sid" != "$bid" ]; then
    echo "error: $(basename "$bundle") is signed as '$sid' but its CFBundleIdentifier is '$bid'" >&2
    return 1
  fi
}
_id_ok=1
for _bundle in "$APP" "$H"/*.app; do
  verify_identifier "$_bundle" "$_bundle/Contents/Info.plist" || _id_ok=0
done
verify_identifier "$FW" "$FW/Resources/Info.plist" || _id_ok=0
[ "$_id_ok" = 1 ] || exit 1
echo "    signing identifiers match CFBundleIdentifier for the app, framework and every helper"
spctl --assess --type execute --verbose=4 "$APP" || echo "   (spctl will only pass once the app is notarized)"

# Start the signed app before spending a notarization on it: a build that
# crashes on launch, or one where MV2 extensions stopped working, passes every
# check above. EUROPIUM_SKIP_SMOKE=1 skips it (e.g. no network stack to bind).
if [ "${EUROPIUM_SKIP_SMOKE:-0}" != 1 ]; then
  "$HERE/scripts/smoke-test.sh" "$APP"
fi

if [ "$DO_NOTARIZE" = 1 ]; then
  echo "==> Notarizing (profile: $NOTARY_PROFILE)"
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
  package_dmg "$APP" "$DMG"

  # The .app inside is already notarized+stapled, but the disk image itself must
  # also be signed and notarized or Gatekeeper rejects it on download.
  echo "==> Signing the disk image"
  codesign --sign "$CODESIGN_ID" --force --timestamp "$DMG"
  echo "==> Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "==> Disk image assessment (as a downloader would see it):"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  echo "==> Checking the app inside the disk image:"
  if ! verify_dmg "$DMG" "$V"; then
    # Take the bad image out of the way: it is signed and notarized, and
    # update-tap.sh would otherwise pick it up as the newest .dmg.
    mv "$DMG" "$DMG.failed-verification"
    echo "error: the disk image failed verification; kept as $DMG.failed-verification" >&2
    exit 1
  fi
  echo "    signature, Gatekeeper, notarization ticket and version all good"
  echo "    -> $DMG"
fi

echo "==> Done."
