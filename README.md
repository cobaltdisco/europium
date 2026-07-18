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

Everything else is stock ungoogled-chromium: no reskin, no relayout, no changed icon.

All five are plain unified diffs against pristine Chromium source, in [`patches/`](patches).

## Please read before using

- **Apple Silicon only.** There is no Intel build.
- **No auto-updater.** Chromium's updater is disabled in ungoogled-chromium, so this build never updates itself. Updates arrive only when you run `brew upgrade --cask europium` (or download a new `.dmg`).
- **Update cadence.** Releases here follow [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos), which normally lags Chrome stable.
- **No DRM.** The Widevine CDM is not bundled, so Netflix/Spotify-style DRM playback won't work out of the box.
- **Unofficial.** A personal build, not affiliated with, endorsed by, or sponsored by Google or the Chromium project.

## Build it yourself

```bash
git clone --recurse-submodules https://github.com/ungoogled-software/ungoogled-chromium-macos.git
scripts/install-custom-patches.sh ungoogled-chromium-macos   # copy patches in + register in series
cd ungoogled-chromium-macos
PATH="/opt/homebrew/opt/python@3.13/libexec/bin:$PATH" ./build.sh
```

## License

BSD 3-Clause — see [LICENSE](LICENSE), which also carries the Chromium / ungoogled-chromium / Helium attributions.
