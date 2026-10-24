# Europium

A macOS build of [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium). Requires a Mac with Apple Silicon.

## What's different

- Extensions can't add items to the right-click menu.
- "Open in reading mode" and "Create QR Code for this Page" are removed from the right-click menu.
- Extensions that ask you to sign in, such as Claude, stay signed in after a restart. This doesn't work in ungoogled-chromium.
- Europium keeps its own settings and data, so it can be installed alongside Chrome or Chromium.
- Gets Google's certificate revocation list (CRLSet) and Certificate Transparency updates, which ungoogled-chromium turns off. Once an update arrives, certificates Chrome blocks in an emergency are blocked here too. These two are the only things Europium fetches from Google's update service (it checks update.googleapis.com and downloads from Google's download servers); no other components or extensions are updated.
- PGO is enabled.

## Install

With [Homebrew](https://brew.sh):

```bash
brew tap cobaltdisco/europium
brew install --cask europium
```

To update later:

```bash
brew upgrade --cask europium
```

Or download the `.dmg` from [Releases](https://github.com/cobaltdisco/europium/releases).

## Patches

| Patch | What it does |
|---|---|
| `disable-extension-context-menu-items` | Stops extensions from adding items to right-click menus |
| `remove-reading-mode-and-qrcode-menu-items` | Removes the reading mode and QR code items from the right-click menu |
| `rebrand-europium` | Changes the app name to Europium |
| `macos-product-dir-name` | Stores settings and data in a separate folder from Chromium |
| `macos-keychain-name` | Uses a separate Keychain entry from Chromium |
| `enable-security-component-updates` | Lets only the certificate revocation list (CRLSet) and certificate metadata (CT logs, root store) update from Google |
| `macos-native-messaging-fallback` | Lets apps like 1Password connect to Europium the same way they connect to Chrome or Chromium |

## License

BSD 3-Clause. See [LICENSE](LICENSE) for details and attributions to Chromium, ungoogled-chromium, and Helium.