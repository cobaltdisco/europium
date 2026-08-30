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

cd "$SRC"
echo "==> Bootstrapping GN"
./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles
# NOTE: no build_bindgen.py — Google's rust package ships a prebuilt bindgen.

echo "==> gn gen"
./out/Default/gn gen out/Default --fail-on-unused-args

echo "==> ninja"
ninja -C out/Default chrome chromedriver
echo "==> Done."
