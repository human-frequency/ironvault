# Changelog

## 2.1 (latest)

- Runs on macOS 12 Monterey (12.0 and later) as well as macOS 13 and newer.
- The menu bar menu is built with AppKit. It has the same items as before, and the countdowns keep moving while the menu is open.
- Open at Login uses a small launch agent in `~/Library/LaunchAgents`, which works on every macOS version. Uninstalling removes it.
- Built with the Swift compiler directly instead of Swift Package Manager. This fixes the "Invalid manifest" build error some Command Line Tools installs hit.
- User manual added: `docs/IronVault-User-Manual.pdf`.

Download: [`dist/ironvault.zip`](dist/ironvault.zip). Source: the `main` branch.

## 2.0

- Every file is sealed on its own, and each file opens only after Touch ID names it.
- Edits are sealed back automatically, and decrypted copies are wiped after 15 minutes, on sleep or lock, or on quit.
- Dashboard shows who asked to open vault files and the reads IronVault noticed.
- Requires macOS 13 Ventura or later. It builds with Swift Package Manager, which fails on some Command Line Tools installs; use 2.1 if that happens.

Download: [`dist/ironvault-2.0.0.zip`](dist/ironvault-2.0.0.zip). Source: the [`release-2.0`](../../tree/release-2.0) branch.
