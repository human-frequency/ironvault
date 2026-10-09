#!/bin/zsh -f
# Removes IronVault: the app, the watchdog, the ironvault command and the key.
# Your sealed files in ~/IronVault are kept. Without the key they open only with your
# recovery key (ironvault recover), so make sure you have it before you continue.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LABEL="local.ironmountain.ironvault.watchdog"

print "Your sealed files stay in ~/IronVault. After this, only your recovery key can open them."
read -r "?Remove the IronVault app, watchdog, command and key? [y/N] " answer
[[ "$answer" == [yY] ]] || { print "Nothing was changed."; exit 0; }

osascript -e 'tell application "IronVault" to quit' >/dev/null 2>&1 || true   # saves edits and wipes open copies
sleep 2
sudo launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
sudo rm -f "/Library/LaunchDaemons/$LABEL.plist"
sudo rm -rf "/Applications/IronVault.app" "/Library/IronVault"
rm -rf "$HOME/Library/Caches/IronVault"
rm -f "$HOME/Library/LaunchAgents/local.ironmountain.ironvault.plist"   # Open at Login
sudo -k
print "Removed. Your sealed files are still in ~/IronVault."
