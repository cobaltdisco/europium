#!/usr/bin/env bash
# Europium build orchestration — Google official toolchain edition (D13).
#
# Replaces the upstream shell's build.sh. WHY: the shell's build used a
# privately-built vanilla LLVM pinned per-release, which (a) needed NINE
# compatibility patches (bindgen trio, clang-version-check, unsupported-flags,
# rust-nightly shims, v8-sanitizer revert, clang-format path), and (b) made
# every major Chromium bump wait for someone to hand-build a matching LLVM.
# Chromium's own tools/clang/scripts/update.py and tools/rust/update_rust.py
# download Google's official prebuilt toolchain for the EXACT checked-out
# revision — self-matching forever, zero compat patches (same move Helium
# made). Trust trade-off accepted by PM 2026-08-29: toolchain now comes from
# Google's bucket over TLS (like the PGO profile); the built browser still
# never talks to Google.
#
# Toolchain fetch runs on the PRISTINE tree (before domain substitution would
# rewrite the download URLs inside those scripts) — same ordering as Helium.
#
# Prereqs (run first, both idempotent):
#   scripts/install-custom-patches.sh
#   scripts/pin-pgo-profile.sh
#
# Usage: scripts/build-europium.sh [path-to-clone] [arch]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONE="${1:-$HERE/ungoogled-chromium-macos}"
ARCH="${2:-arm64}"
MAIN="$CLONE/ungoogled-chromium"
SRC="$CLONE/build/src"
CACHE="$CLONE/build/download_cache"
SERIES="$CLONE/patches/series"

# depot_tools needs python <= 3.13
export PATH="/opt/homebrew/opt/python@3.13/libexec/bin:$PATH"

[ -f "$MAIN/chromium_version.txt" ] || { echo "error: core submodule missing" >&2; exit 1; }
echo "==> Building Europium $(cat "$MAIN/chromium_version.txt") ($ARCH)"

# Every build is from-scratch for the out dir (same policy as upstream).
rm -rf "$SRC/out"
mkdir -p "$CACHE"

echo "==> Fetching Chromium source (clone.py; depot_tools pinned via DEPS)"
# Call clone.py directly: the shell's retrieve_and_unpack_resource.sh was only
# a thin wrapper around it, and upstream deleted/rewrote that wrapper in their
# 152 update — going straight to the core utility survives such refactors.
case "$ARCH" in
  arm64) _clone_platform="mac-arm" ;;
  *)     _clone_platform="mac" ;;
esac
python3 "$MAIN/utils/clone.py" -p "$_clone_platform" -o "$SRC"
# When a DEPS entry disappears (153 dropped third_party/aria-practices), gclient
# moves the stale checkout's .git aside as old_<path>.git in ITS cwd — which is
# this repo's root. Pure leftover metadata; sweep it so it never lands in git status.
for leftover in "$HERE"/old_*_build_src_*.git; do
  [ -e "$leftover" ] || continue
  echo "==> Removing gclient leftover $(basename "$leftover")"; rm -rf "$leftover"
done

echo "==> Pruning binaries"
python3 "$MAIN/utils/prune_binaries.py" "$SRC" "$MAIN/pruning.list"

echo "==> Fetching Google's official toolchain (matched to this revision)"
pushd "$SRC" >/dev/null
python3 tools/rust/update_rust.py
for pkg in clang objdump clang-tidy libclang; do
  python3 tools/clang/scripts/update.py --package "$pkg"
done
third_party/node/update_node_binaries
if [ "$ARCH" = arm64 ] && [ -d third_party/node/mac/node-darwin-arm64 ]; then
  mkdir -p third_party/node/mac_arm64
  rm -rf third_party/node/mac_arm64/node-darwin-arm64
  mv third_party/node/mac/node-darwin-arm64 third_party/node/mac_arm64/
fi
popd >/dev/null

echo "==> Dropping the 9 vanilla-toolchain compat patches from series"
for p in build-bindgen build-bindgen-target-override bindgen-disable-static \
         disable-clang-version-check fix-build-with-rust fix-clang-format-path \
         set-rustc-nightly-capability disable-unsupported-llvm-flags \
         revert-v8-sanitizer-changes; do
  /usr/bin/sed -i '' "\|^ungoogled-chromium/macos/$p\.patch$|d" "$SERIES"
done

echo "==> Applying patches"
python3 "$MAIN/utils/patches.py" apply "$SRC" "$MAIN/patches" "$CLONE/patches"

echo "==> Domain substitution"
python3 "$MAIN/utils/domain_substitution.py" apply -r "$MAIN/domain_regex.list" \
  -f "$MAIN/domain_substitution.list" "$SRC"

echo "==> GN args"
mkdir -p "$SRC/out/Default"
cat "$MAIN/flags.gn" "$CLONE/flags.macos.gn" > "$SRC/out/Default/args.gn"
echo "target_cpu = \"$ARCH\"" >> "$SRC/out/Default/args.gn"
grep -q "^pgo_data_path=" "$SRC/out/Default/args.gn" \
  || { echo "error: pgo_data_path missing — run scripts/pin-pgo-profile.sh first" >&2; exit 1; }

# Pin the macOS SDK to the exact version Chromium's own official builds use
# (mac_sdk_official_version in build/config/mac/mac_sdk.gni). WHY: left alone,
# gn takes whatever xcrun reports, i.e. the newest SDK inside Xcode.app. Xcode
# 27.0 GM (installed 2026-09-15) ships an SDK whose .tbd stubs list the new
# `arm64e.x1` target; 153's pinned lld (llvmorg-24-init-3796) predates LLVM's
# support for it and rejects every stub as "malformed file ... unknown target",
# so nothing links. The official version is what Google's bots build this
# revision with, hence the one SDK known to match this toolchain. Xcode's SDK
# dir is searched first, then the Command Line Tools' (Apple leaves older SDKs
# there). No matching SDK installed -> keep the default and say so: newer SDKs
# usually work, and did until Xcode 27.0 GM. GN insists the SDK path lie inside
# the out dir (build/config/mac/BUILD.gn "sdk_inputs"), so hand it a symlink in
# sdk/xcode_links/ exactly as sdk_info.py does for Xcode's own SDK. (find_sdk.py
# still reports Xcode's newest version for DTSDKName in Info.plist; cosmetic,
# compile and link use the pinned SDK.)
_sdk_official="$(sed -n 's/^ *mac_sdk_official_version = "\([^"]*\)".*/\1/p' "$SRC/build/config/mac/mac_sdk.gni" | head -1)"
[ -n "$_sdk_official" ] || { echo "error: mac_sdk_official_version not found in build/config/mac/mac_sdk.gni" >&2; exit 1; }
_sdk_path=""
for _d in "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs" /Library/Developer/CommandLineTools/SDKs; do
  for _s in "$_d"/MacOSX*.sdk; do
    [ -d "$_s" ] || continue
    [ "$(/usr/libexec/PlistBuddy -c 'Print Version' "$_s/SDKSettings.plist" 2>/dev/null)" = "$_sdk_official" ] || continue
    _sdk_path="$(cd "$_s" && pwd -P)"; break 2
  done
done
if [ -n "$_sdk_path" ]; then
  echo "==> macOS SDK: $_sdk_official at $_sdk_path (Chromium's official SDK version)"
  mkdir -p "$SRC/out/Default/sdk/xcode_links"
  ln -sfn "$_sdk_path" "$SRC/out/Default/sdk/xcode_links/MacOSX${_sdk_official}.sdk"
  echo "mac_sdk_path = \"//out/Default/sdk/xcode_links/MacOSX${_sdk_official}.sdk\"" >> "$SRC/out/Default/args.gn"
else
  echo "==> macOS SDK: no $_sdk_official SDK installed; using Xcode's default $(xcrun --show-sdk-version) (may be newer than this toolchain's lld understands)"
fi

# Dawn's Tint source generator needs a Go toolchain. Read the exact version
# Dawn itself pins in its DEPS (never goes stale — Helium's technique).
_cipd="$SRC/third_party/depot_tools/cipd"
case "$(uname -m)" in
  arm64)  _go_platform="mac-arm64" ;;
  x86_64) _go_platform="mac-amd64" ;;
  *) echo "unsupported host: $(uname -m)" >&2; exit 1 ;;
esac
_go_version="$(sed -n "s/.*'dawn_go_version': '\\([^']*\\)'.*/\\1/p" "$SRC/third_party/dawn/DEPS" | head -1)"
[ -n "$_go_version" ] || { echo "error: dawn_go_version not found in dawn/DEPS" >&2; exit 1; }
echo "==> Go for Dawn: $_go_version"
printf 'infra/3pp/tools/go/%s %s\n' "$_go_platform" "$_go_version" | \
  "$_cipd" ensure -cache-dir "$CACHE/cipd" \
    -root "$SRC/third_party/dawn/tools/golang/$_go_platform" -ensure-file -

# Chromium 153 made the WebUI TypeScript compiler a prebuilt cipd package
# (chromium/third_party/typescript/<platform>, see third_party/typescript/tsgo.gni)
# that only gclient installs; ninja fails at once without lib/tsc. Install the
# exact version DEPS pins, same mechanism as the Go step above. (Arch instead
# patches tsgo off and uses a system tsc — more moving parts than one cipd pull.)
_ts_platform="${_go_platform}"   # same mac-arm64 / mac-amd64 naming
_ts_version="$(python3 - "$SRC/DEPS" "$_ts_platform" <<'PY'
import re, sys
deps = open(sys.argv[1]).read()
m = re.search(r"'src/third_party/typescript/%s/src':\s*\{.*?'version':\s*'([^']+)'" % re.escape(sys.argv[2]), deps, re.S)
print(m.group(1) if m else "")
PY
)"
[ -n "$_ts_version" ] || { echo "error: typescript cipd version for $_ts_platform not found in DEPS" >&2; exit 1; }
echo "==> TypeScript (tsc) for WebUI: $_ts_version"
printf 'chromium/third_party/typescript/%s %s\n' "$_ts_platform" "$_ts_version" | \
  "$_cipd" ensure -cache-dir "$CACHE/cipd" \
    -root "$SRC/third_party/typescript/$_ts_platform/src" -ensure-file -
[ -x "$SRC/third_party/typescript/$_ts_platform/src/lib/tsc" ] \
  || { echo "error: tsc missing after cipd ensure" >&2; exit 1; }

cd "$SRC"
echo "==> Bootstrapping GN"
./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles
# NOTE: no build_bindgen.py — Google's rust package ships a prebuilt bindgen.

echo "==> gn gen"
# Chromium 153 pointed .gn's script_executable at a hermetic CPython that only
# gclient installs (cipd infra/3pp/tools/cpython3 -> third_party/cpython3/host,
# which ungoogled's pruning list deletes anyway). WHY not fetch it: every build
# action already ran on the system python3 (python@3.13 via PATH above) through
# 152, and Arch / ungoogled-chromium-windows both revert 153 to the system
# interpreter with a patch. --script-executable does the same without a patch;
# GN bakes it into the ninja files so actions use it too.
_py3="$(command -v python3)"
echo "==> script_executable: $_py3 ($("$_py3" --version 2>&1))"
./out/Default/gn gen out/Default --fail-on-unused-args --script-executable="$_py3"

echo "==> ninja"
ninja -C out/Default chrome chromedriver
echo "==> Done."
