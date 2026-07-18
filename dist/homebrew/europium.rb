# Homebrew Cask for Europium.
#
# This belongs in our own tap, NOT in Homebrew/homebrew-cask — the official repo
# rejects forks ("Not a fork (usually)") and applies a 90 forks / 90 watchers /
# 225 stars threshold to self-submitted casks.
#
# Tap layout:    cobaltdisco/homebrew-europium/Casks/europium.rb
# Users install: brew tap cobaltdisco/europium && brew install --cask europium
# Users update:  brew upgrade --cask europium
#
# On each release: publish the .dmg, then bump `version` and `sha256` here.
cask "europium" do
  version "150.0.7871.46-1.1.1"
  sha256 "a02f96433ef9024825328e26eb9c103aa54b11cff614de5164f26be392907790"

  # No `verified:` here on purpose: the url and homepage share a domain, and
  # Homebrew's audit_unnecessary_verified then treats `verified:` as an error.
  url "https://github.com/cobaltdisco/europium/releases/download/#{version}/europium_#{version}_macos.dmg"
  name "Europium"
  desc "Chromium build without Google integration and without extension context-menu items"
  homepage "https://github.com/cobaltdisco/europium"

  livecheck do
    url :url
    strategy :github_latest
    # The default :github_latest regex is /v?(\d+(?:\.\d+)+)/i, which would capture
    # only "150.0.7871.46" and silently drop our "-1.1.1" suffix — livecheck would
    # then think the cask is permanently newer than upstream. Match the full tag.
    regex(/^v?(\d+(?:\.\d+)+-\d+(?:\.\d+)*)$/i)
  end

  # Apple Silicon only. Without this, Intel users would install a binary that
  # cannot run; with it Homebrew refuses up front with a clear message.
  depends_on arch: :arm64
  # The app bundle's LSMinimumSystemVersion is 12.0; the string-comparison form
  # (">= :monterey") is deprecated, the symbol form already means "or newer".
  depends_on macos: :monterey

  app "Europium.app"

  # Everything Europium writes is namespaced by our product-dir / bundle-id
  # patches, so a zap is clean and cannot touch a stock Chromium install.
  zap trash: [
    "~/Library/Application Support/Europium",
    "~/Library/Caches/Europium",
    "~/Library/HTTPStorages/com.fx.europium",
    "~/Library/Preferences/com.fx.europium.plist",
    "~/Library/Saved Application State/com.fx.europium.savedState",
  ]
  # Note: the "Europium Safe Storage" Keychain item is intentionally NOT zapped —
  # Homebrew cannot remove Keychain entries; delete it manually if desired.
end
