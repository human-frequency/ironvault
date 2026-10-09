#!/bin/zsh -f
# IronVault self-test. Run it after install.sh.
# Touch ID asks once. It seals and opens test files made just for this, cleans up after
# itself, and never touches your own files. Results are saved to selftest-result.txt.
# When everything passes it marks IronVault as verified, which turns on deleting
# originals after sealing and auto-sealing files dropped into the IronVault folder.
set -uo pipefail
setopt null_glob
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

IV="/Library/IronVault/bin/ironvault"
ROOT_DIR="/Library/IronVault"
LABEL="local.ironmountain.ironvault.watchdog"
VAULT_DIR="$(sed -n 's/^VAULT_DIR=//p' "$ROOT_DIR/config" 2>/dev/null)"
OPEN_DIR="$HOME/Library/Caches/IronVault/open.noindex"
OUT="${0:A:h:h}/selftest-result.txt"
TMP="$(mktemp -d)"
TAG="ironvault-selftest-$$"
PASS=0; FAIL=0

exec > >(tee "$OUT") 2>&1

ok()    { print "  PASS  $1"; (( PASS++ )); }
bad()   { print "  FAIL  $1"; (( FAIL++ )); }
# check "what is being tested" 'shell condition'
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
wait_for() { local secs="$1" i; shift; for i in {1..$secs}; do eval "$*" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
cleanup() {
  rm -rf "$TMP" "$VAULT_DIR"/$TAG* "$OPEN_DIR/$TAG" 2>/dev/null
  open -g /Applications/IronVault.app 2>/dev/null
}
trap cleanup EXIT

print "IronVault self-test · $(date) · macOS $(sw_vers -productVersion) · $(uname -m)"

print "\n1. Installation"
check "config is owned by root"                '[[ "$(stat -f %u $ROOT_DIR/config)" == 0 ]]'
check "private key can't be read by your apps" '! cat $ROOT_DIR/key/private.key'
check "key folder can't be listed"             '! ls $ROOT_DIR/key'
check "public key is root-owned"               '[[ "$(stat -f %u $ROOT_DIR/public.key)" == 0 && ! -w $ROOT_DIR/public.key ]]'
check "ironvault command is root-owned"        '[[ "$(stat -f %u $IV)" == 0 && ! -w $IV ]]'
check "app is root-owned"                      '[[ "$(stat -f %u /Applications/IronVault.app)" == 0 ]]'
check "watchdog is loaded"                     'launchctl print system/$LABEL'
check "vault folder exists"                    '[[ -n "$VAULT_DIR" && -d "$VAULT_DIR" ]]'
[[ -n "$VAULT_DIR" && -d "$VAULT_DIR" ]] || { print "\nIronVault isn't installed correctly. Run install.sh first."; exit 1; }

print "\n2. Sealing"
SECRET="$TAG secret text $(openssl rand -hex 16)"
print -- "$SECRET" > "$TMP/$TAG.txt"
head -c 3000000 /dev/urandom > "$TMP/$TAG.bin"
mkdir -p "$TMP/$TAG.rtfd"; print -- "$SECRET" > "$TMP/$TAG.rtfd/TXT.rtf"; print "two" > "$TMP/$TAG.rtfd/other.txt"
check "seals a text file (no Touch ID needed)"  '"$IV" add --keep "$TMP/$TAG.txt"'
check "seals a 3 MB binary file"                '"$IV" add --keep "$TMP/$TAG.bin"'
check "seals a package folder"                  '"$IV" add --keep "$TMP/$TAG.rtfd"'
check "sealed files are in the vault folder"    '[[ -f "$VAULT_DIR/$TAG.txt.ivault" && -f "$VAULT_DIR/$TAG.bin.ivault" && -f "$VAULT_DIR/$TAG.rtfd.ivault" ]]'
check "sealed file doesn't contain the text"    '! grep -q "$SECRET" "$VAULT_DIR/$TAG.txt.ivault"'
check "sealed file starts with the IronVault header" '[[ "$(head -c 8 "$VAULT_DIR/$TAG.txt.ivault")" == IRONVLT1 ]]'
check "originals kept with --keep"              '[[ -f "$TMP/$TAG.txt" ]]'

print "\n3. Opening needs the key"
print "  … Touch ID: open the test files (one approval covers this section)"
# The key is piped straight from the root-only file into each test and never written to disk.
sudo -k -v
key() { sudo -n /bin/cat "$ROOT_DIR/key/private.key"; }
mkdir -p "$TMP/out"
check "text file opens to the exact original"   'key | "$IV" recover "$VAULT_DIR/$TAG.txt.ivault" "$TMP/out" && cmp "$TMP/$TAG.txt" "$TMP/out/$TAG.txt"'
check "binary file opens to the exact original" 'key | "$IV" recover "$VAULT_DIR/$TAG.bin.ivault" "$TMP/out" && cmp "$TMP/$TAG.bin" "$TMP/out/$TAG.bin"'
check "package opens to the exact original"     'key | "$IV" recover "$VAULT_DIR/$TAG.rtfd.ivault" "$TMP/out" && diff -r "$TMP/$TAG.rtfd" "$TMP/out/$TAG.rtfd"'
check "a different key can't open it"           'openssl rand -base64 32 | "$IV" recover "$VAULT_DIR/$TAG.txt.ivault" "$TMP/wrong"; [[ $? -ne 0 && ! -e "$TMP/wrong/$TAG.txt" ]]'
cp "$VAULT_DIR/$TAG.txt.ivault" "$TMP/tampered.ivault"
printf '\xff' | dd of="$TMP/tampered.ivault" bs=1 seek=60 conv=notrunc 2>/dev/null
check "a changed byte is detected"              'key | "$IV" recover "$TMP/tampered.ivault" "$TMP/tampered"; [[ $? -ne 0 && ! -e "$TMP/tampered/$TAG.txt" ]]'

if (( FAIL == 0 )); then
  sudo -n /usr/bin/touch "$ROOT_DIR/verified" && sudo -n chmod 644 "$ROOT_DIR/verified"
  check "IronVault marked as verified"          '[[ -f $ROOT_DIR/verified && "$(stat -f %u $ROOT_DIR/verified)" == 0 ]]'
else
  print "  Not marking IronVault as verified, because something above failed."
fi
sudo -k

print "\n4. Files dropped into the IronVault folder get sealed (up to 30 seconds)"
if [[ -f "$ROOT_DIR/verified" ]]; then
  print -- "$SECRET" > "$VAULT_DIR/$TAG-dropped.txt"
  check "plain file was sealed"                 'wait_for 30 "[[ -f \"$VAULT_DIR/$TAG-dropped.txt.ivault\" ]]"'
  check "plain original was removed"            '[[ ! -e "$VAULT_DIR/$TAG-dropped.txt" ]]'
else
  print "  Skipped until the checks above pass."
fi

print "\n5. Decrypted copies are wiped if the app isn't running (up to 30 seconds)"
osascript -e 'tell application "IronVault" to quit' >/dev/null 2>&1
sleep 2
mkdir -p "$OPEN_DIR/$TAG" && print -- "$SECRET" > "$OPEN_DIR/$TAG/leftover.txt"
check "watchdog wiped the leftover copy"        'wait_for 30 "[[ ! -e \"$OPEN_DIR/$TAG\" ]]"'

print "\n6. Dashboard notices direct reads (up to 60 seconds)"
LOG="$HOME/Library/Application Support/IronVault/activity.log"
print -- "$SECRET" > "$TMP/$TAG-watch.txt"
"$IV" add --keep "$TMP/$TAG-watch.txt" >/dev/null 2>&1
W="$VAULT_DIR/$TAG-watch.txt.ivault"
check "this Mac records when a file is read"    '[[ "$("$IV" _readcheck "$W")" == yes ]]'
STATE="$HOME/Library/Application Support/IronVault/watch-state.json"
check "watchdog is watching the new file"       'wait_for 30 "grep -q \"$TAG-watch.txt.ivault\" \"$STATE\""'
cat "$W" > /dev/null
check "a direct read shows up in the Dashboard"  'wait_for 30 "grep kind.:.read \"$LOG\" | grep -q \"$TAG-watch.txt.ivault\""'
print "  (Your Dashboard will list these test reads under names starting with ironvault-selftest.)"

print "\n7. Check these yourself (the app is reopening now)"
print "  • In Finder, open your IronVault folder and double-click any .ivault file."
print "    Touch ID asks, naming the file. The document opens in its usual app."
print "  • Press Cancel on that prompt instead: nothing opens."
print "  • Edit and save an open document, choose Close and Wipe from the menu bar, then"
print "    open it again: your edit is there."
print "  • Open the Dashboard from the menu bar: your test opens and reads are listed."
print "  • With a document open, lock your screen (Control-Command-Q). Log back in: the"
print "    menu bar shows no open documents."

print "\nResult: $PASS passed, $FAIL failed. Saved to $OUT"
(( FAIL == 0 ))
