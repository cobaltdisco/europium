# Europium

A macOS build of [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium) with one extra goal: **no browser extension can put items into your right-click menus.**

Signed with a Developer ID certificate and notarized by Apple.

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

Everything else is stock ungoogled-chromium: no reskin, no relayout, no changed icon.

All five are plain unified diffs against pristine Chromium source, in [`patches/`](patches).

## Please read before using

- **Apple Silicon only.** There is no Intel build; Homebrew refuses to install on Intel rather than give you an app that cannot run.
- **No auto-updater.** Chromium's updater is disabled in ungoogled-chromium, so this build never updates itself. Updates arrive only when you run `brew upgrade --cask europium` (or download a new `.dmg`). **A browser you don't update is a security risk** — Chromium ships fixes for actively exploited bugs every few weeks.
- **Update cadence.** Releases here follow [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos), which normally lags Chrome stable. This release is built on Chromium `150.0.7871.46`.
- **No DRM.** The Widevine CDM is not bundled, so Netflix/Spotify-style DRM playback won't work out of the box.
- **Unofficial.** A personal build, not affiliated with, endorsed by, or sponsored by Google or the Chromium project. "Chromium" and the Chromium logo are trademarks of Google LLC.

## Build it yourself

```bash
git clone --recurse-submodules https://github.com/ungoogled-software/ungoogled-chromium-macos.git
scripts/install-custom-patches.sh ungoogled-chromium-macos   # copy patches in + register in series
cd ungoogled-chromium-macos
PATH="/opt/homebrew/opt/python@3.13/libexec/bin:$PATH" ./build.sh
```

Notes:

- Homebrew deps: `python@3.13` (depot_tools needs ≤3.13 — the build calls a bare `python3`, hence the `PATH` prefix above), `ninja`, `coreutils` (for `greadlink`), `node`, and `perl` if you want a `.dmg`. Also run `xcodebuild -downloadComponent MetalToolchain` once, and keep Xcode open during the build.
- Expect a multi-hour first build and ~150 GB of disk.
- `scripts/sign-and-package.sh --dmg --install` then signs, notarizes, staples, installs to `/Applications` and builds the `.dmg`. It needs your own Developer ID certificate and a `notarytool` keychain profile; it never handles a password itself.
- `scripts/update-tap.sh` points the Homebrew tap at a new release (verifies the dmg is notarized and the release asset is published before touching the cask).

## License

BSD 3-Clause — see [LICENSE](LICENSE), which also carries the Chromium / ungoogled-chromium / Helium attributions.
