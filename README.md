# Europium

A macOS build of [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium) with one extra goal: **No browser extension can put items into your right-click menus.**

## Install

```bash
brew tap cobaltdisco/europium
brew install --cask europium
```

Update later with `brew upgrade --cask europium`.

Or grab the `.dmg` from [Releases](https://github.com/cobaltdisco/europium/releases).

## What's different from stock ungoogled-chromium

| Patch | What it does |
|---|---|
| `disable-extension-context-menu-items` | Extensions can no longer add items to the **page, tab-strip or webview** right-click menus. Their own toolbar-icon menu still works. |
| `rebrand-europium` | Renames the product to Europium, bundle id `com.fx.europium`. |
| `macos-product-dir-name` | Own profile dir `~/Library/Application Support/Europium` — runs side by side with a stock Chromium install. |
| `macos-keychain-name` | Own Keychain item instead of sharing "Chromium Safe Storage". |
| `macos-native-messaging-fallback` | Still finds native messaging hosts (1Password, Dropbox, …) that apps installed for Chromium or Google Chrome. |
| `remove-reading-mode-and-qrcode-menu-items` | Removes "Open in reading mode" and "Create QR Code for this Page" from the page right-click menu. The address-bar sharing hub is untouched. |

Everything else is stock ungoogled-chromium: no reskin, no relayout, no changed icon. One build-config difference: PGO is enabled (see Notes under "Build it yourself").

All six are plain unified diffs against pristine Chromium source, in [`patches/`](patches).

## Please read before using

- **Apple Silicon only.** There is no Intel build. Requires macOS 13 or newer (raised by Chromium 151).
- **No auto-updater.** Chromium's updater is disabled in ungoogled-chromium, so this build never updates itself. Updates arrive only when you run `brew upgrade --cask europium` (or download a new `.dmg`).
- **Update cadence.** Releases here follow [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos), which normally lags Chrome stable.
- **No DRM.** The Widevine CDM is not bundled, so Netflix/Spotify-style DRM playback won't work out of the box.
- **Unofficial.** A personal build, not affiliated with, endorsed by, or sponsored by Google or the Chromium project.

## Build it yourself

```bash
git clone --recurse-submodules https://github.com/ungoogled-software/ungoogled-chromium-macos.git
scripts/install-custom-patches.sh ungoogled-chromium-macos   # copy patches in + register in series
scripts/pin-rust-hash.sh ungoogled-chromium-macos            # adds the missing Rust checksum — see the note below
scripts/pin-pgo-profile.sh ungoogled-chromium-macos          # enables PGO — see the note below
cd ungoogled-chromium-macos
PATH="/opt/homebrew/opt/python@3.13/libexec/bin:$PATH" ./build.sh
```

Notes:

- **`pin-pgo-profile.sh` re-enables profile-guided optimization**, which stock ungoogled-chromium turns off because its build refuses to fetch anything from Google. Official Chrome is compiled against a published profile of which code paths real browsing uses most (~5–10% on browser benchmarks); this script downloads the profile matching the exact Chromium version being built, verifies it against the checksum embedded in its filename, and points the build at it. Deliberate trade-off: this is one build-time download from a Google bucket, on the build machine only — the built browser still never talks to Google. Skip this script for a build with zero Google contact.
- **`pin-rust-hash.sh` closes an upstream integrity gap.** ungoogled-chromium-macos pins checksums for its llvm and nodejs downloads but ships no hash for the ~200 MB Rust toolchain tarball, and the downloader silently skips verification for hashless entries. The script fetches the checksum Rust itself publishes for that exact file and writes it into the download manifest, so every build verifies the tarball. Re-run it after a fresh clone or an upstream Rust version bump.
- Homebrew deps: `python@3.13` (depot_tools needs ≤3.13 — the build calls a bare `python3`, hence the `PATH` prefix above), `ninja`, `coreutils` (for `greadlink`), `node`, and `perl` if you want a `.dmg`. Also run `xcodebuild -downloadComponent MetalToolchain` once, and keep Xcode open during the build.
- Expect a multi-hour first build and ~150 GB of disk.
- `scripts/sign-and-package.sh --dmg --install` then signs, notarizes, staples, installs to `/Applications` and builds the `.dmg`. It needs your own Developer ID certificate and a `notarytool` keychain profile; it never handles a password itself.
- `scripts/update-tap.sh` points the Homebrew tap at a new release (verifies the dmg is notarized and the release asset is published before touching the cask).

## License

BSD 3-Clause — see [LICENSE](LICENSE), which also carries the Chromium / ungoogled-chromium / Helium attributions.
