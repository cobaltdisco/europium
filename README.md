# Europium

A macOS build of [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium) with three main changes:

- No browser extension can put items into your right-click context menu.
- Remove "Open in reading mode" and "Create QR Code for this Page" from right-click context menu.
- PGO is enabled.

## 1. How to install

```bash
brew tap cobaltdisco/europium
brew install --cask europium
```

Update later with `brew upgrade --cask europium`, or grab the `.dmg` from [Releases](https://github.com/cobaltdisco/europium/releases).

Requires Apple Silicon and macOS 13 or newer (raised by Chromium 151); there is no Intel build.

## 2. Six patches

| Patch | What it does |
|---|---|
| `disable-extension-context-menu-items` | Extensions can no longer add items to the page, tab-strip, or webview right-click menus |
| `remove-reading-mode-and-qrcode-menu-items` | Removes "Open in reading mode" and "Create QR Code for this Page" |
| `rebrand-europium` | Renames the product to Europium, bundle id `com.fx.europium` |
| `macos-product-dir-name` | Own profile dir `~/Library/Application Support/Europium`, so it runs side by side with stock Chromium |
| `macos-keychain-name` | Own Keychain item instead of sharing "Chromium Safe Storage" |
| `macos-native-messaging-fallback` | Still finds native messaging hosts (1Password, Dropbox, …) that apps installed for Chromium or Google Chrome |

## License

BSD 3-Clause — see [LICENSE](LICENSE), which also carries the Chromium / ungoogled-chromium / Helium attributions.