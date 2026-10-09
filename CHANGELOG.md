# Changelog

## 2.0 (latest)

- Every file is sealed on its own, and each file opens only after Touch ID names it.
- Edits are sealed back automatically, and decrypted copies are wiped after 15 minutes, on sleep or lock, or on quit.
- Dashboard shows who asked to open vault files and the reads IronVault noticed.
- Requires macOS 13 Ventura or later.

Download: [`dist/ironvault.zip`](dist/ironvault.zip). Source: the `main` branch.

## 2.1

- Runs on macOS 12 Monterey (12.0 and later) as well as macOS 13 and newer.
- The menu bar menu is built with AppKit, with the same items, and the countdowns keep moving while it's open.
- Open at Login uses a small launch agent in `~/Library/LaunchAgents`. Uninstalling removes it.
- Built with the Swift compiler directly instead of Swift Package Manager. Use 2.1 if 2.0's build fails with "Invalid manifest".

Download: [`dist/ironvault-2.1.0.zip`](dist/ironvault-2.1.0.zip). Source: the [`release-2.1`](../../tree/release-2.1) branch.
