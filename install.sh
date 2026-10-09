#!/bin/zsh -f
# IronVault installer.
# Run it in a fresh Terminal window with every AI app, agent and coding tool quit.
#
# First run: builds the app, creates the vault key pair and the IronVault folder, and installs
# the app, the ironvault command and the watchdog. Later runs keep your key and files and
# update everything else.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT_DIR="/Library/IronVault"
KEY_DIR="$ROOT_DIR/key"
PRIVATE_KEY="$KEY_DIR/private.key"
PUBLIC_KEY="$ROOT_DIR/public.key"
CONFIG="$ROOT_DIR/config"
VAULT_DIR="$HOME/IronVault"
LABEL="local.ironmountain.ironvault.watchdog"
DAEMON="/Library/LaunchDaemons/$LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
HERE="${0:A:h}"
BUILD="$HERE/build"

die()  { print -u2 -- "$1"; exit 1; }
step() { print -- "\n▸ $1"; }

# --- Checks before anything changes ---------------------------------------------
[[ "$EUID" -ne 0 ]] || die "Run this as yourself, not with sudo. It asks for permission when it needs it."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 12 ]] || die "IronVault needs macOS 12 Monterey or later."
for f in app/Package.swift app/Info.plist scripts/build-app.sh launchd/$LABEL.plist; do
  [[ -f "$HERE/$f" ]] || die "Missing $f. Run install.sh from inside the unzipped ironvault folder."
done
[[ "$HERE" != "$HOME/Library/Mobile Documents"* ]] || die "Move the ironvault folder out of iCloud Drive first."
xcrun swiftc --version >/dev/null 2>&1 \
  || die "IronVault is built on your Mac and needs Apple's Command Line Tools. Run: xcode-select --install, then run this again."

# --- Build first, so a failed build changes nothing -----------------------------
step "Building IronVault (this takes a minute the first time)"
zsh -f "$HERE/scripts/build-app.sh" || die "The build failed, so nothing was installed. Try the \"If the build fails\" steps in the README, or send the error above."

print "\nmacOS will ask for Touch ID or your password a few times."
sudo -v || die "Administrator permission is needed to install IronVault."

FRESH=1
sudo test -f "$PRIVATE_KEY" && FRESH=0

# --- Key pair (first run only) ---------------------------------------------------
if (( FRESH )); then
  step "Creating your vault key"
  sudo mkdir -p "$KEY_DIR" "$ROOT_DIR/bin"
  sudo chown -R root:wheel "$ROOT_DIR"
  sudo chmod 755 "$ROOT_DIR" "$ROOT_DIR/bin"
  sudo chmod 700 "$KEY_DIR"
  # The private key goes straight from the generator into the root-only file.
  "$BUILD/ironvault" _keygen | sudo tee "$PRIVATE_KEY" >/dev/null
  sudo chmod 400 "$PRIVATE_KEY"
  sudo tmutil addexclusion -p "$KEY_DIR" >/dev/null 2>&1 || print "  (Couldn't exclude the key from Time Machine. Check it manually.)"
fi

# The public key only seals files. Anyone may read it; only root may change it.
sudo /bin/cat "$PRIVATE_KEY" | "$BUILD/ironvault" _pubkey | sudo tee "$PUBLIC_KEY" >/dev/null \
  || die "The vault key couldn't be read. See Recovery in the README."
sudo chown root:wheel "$PUBLIC_KEY"
sudo chmod 644 "$PUBLIC_KEY"

# --- Vault folder, config, command ----------------------------------------------
step "Setting up the IronVault folder and the ironvault command"
mkdir -p "$VAULT_DIR"
chmod 700 "$VAULT_DIR"
touch "$VAULT_DIR/.metadata_never_index"   # keeps Spotlight from reading vault files
sudo mkdir -p "$ROOT_DIR/bin"
sudo chown root:wheel "$ROOT_DIR" "$ROOT_DIR/bin"
sudo chmod 755 "$ROOT_DIR" "$ROOT_DIR/bin"
printf '%s\n' "VAULT_USER=$USER" "VAULT_HOME=$HOME" "VAULT_DIR=$VAULT_DIR" \
  "OPEN_MINUTES=15" "MAX_OPEN_MINUTES=480" | sudo tee "$CONFIG" >/dev/null
sudo chown root:wheel "$CONFIG"
sudo chmod 644 "$CONFIG"
sudo install -o root -g wheel -m 755 "$BUILD/ironvault" "$ROOT_DIR/bin/ironvault"
# New code has to pass the self-test again before it may delete any originals.
sudo rm -f "$ROOT_DIR/verified"

# --- Watchdog: runs as you, started by the system so it can't be switched off ----
step "Starting the watchdog"
sudo launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
sed "s/__USER__/$USER/" "$HERE/launchd/$LABEL.plist" | sudo tee "$DAEMON" >/dev/null
sudo chown root:wheel "$DAEMON"
sudo chmod 644 "$DAEMON"
sudo launchctl bootstrap system "$DAEMON" || die "The watchdog didn't start. Send the error above."

# --- The app ---------------------------------------------------------------------
step "Installing the IronVault app"
osascript -e 'tell application "IronVault" to quit' >/dev/null 2>&1 || true
sleep 1
sudo rm -rf "/Applications/IronVault.app"
sudo ditto "$BUILD/IronVault.app" "/Applications/IronVault.app"
sudo chown -R root:wheel "/Applications/IronVault.app"
"$LSREGISTER" -f "/Applications/IronVault.app" >/dev/null 2>&1 || true   # so Finder opens .ivault files with IronVault
open "/Applications/IronVault.app"

# --- Recovery key (first run only) -----------------------------------------------
if (( FRESH )); then
  print "\nRecovery key. Save it in your password manager or on paper."
  print "It's the only way to open your files if this Mac is lost:\n"
  sudo /bin/cat "$PRIVATE_KEY"
  print "\n"
  read -r "?Press Return once it is saved. The window will clear. "
  clear
  printf '\e[3J'
fi
sudo -k

print "IronVault is installed. Your vault folder is $VAULT_DIR"
print "Next, run the self-test:  zsh \"$HERE/scripts/selftest.sh\""
