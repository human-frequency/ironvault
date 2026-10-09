# IronVault

Every file in your vault is sealed on its own. No app can read one, AI tools included,
unless you approve that file with Touch ID. Opening one document never opens the others.

## How you use it

- **Add files:** drop them into the **IronVault** folder in your home folder. Within seconds
  each one becomes a sealed `.ivault` file and the plain original is deleted. You can also use
  **Add Files to Vault…** in the menu bar.
- **Open a file:** double-click it in Finder. Touch ID asks, naming that exact file, and the
  document opens in its usual app (Preview, Word, Pages…). Nothing else in the vault opens.
- **Edit:** work as normal. Each time you save, IronVault seals the change back into the vault
  file.
- **Close:** the decrypted copy is wiped 15 minutes after you open it or last save it. It's
  also wiped when you choose **Close and Wipe**, when the Mac sleeps or the screen locks, and
  when you quit IronVault. The lock icon in the menu bar shows what's open and for how long.

Any app that tries to read a vault file directly gets encrypted data. If an app or AI tool
asks IronVault to open one, Touch ID appears on your screen and nothing opens unless you
approve.

## Install in three steps

1. **Get ready.** Quit every AI app, agent and coding tool. Turn on FileVault (System
   Settings › Privacy & Security › FileVault). Then run `xcode-select --install` once and
   wait for it to finish. That installs Apple's free Command Line Tools, which IronVault is
   built with. **You don't need Xcode.** If it says the tools are already installed, you're set.
2. **Install.** Unzip `ironvault.zip` somewhere outside iCloud Drive, open Terminal and run:
   ```sh
   zsh ~/Downloads/ironvault/install.sh
   ```
   Approve the Touch ID or password prompts. At the end it shows your **recovery key** once.
   Save it in your password manager or on paper. It's the only way to open your files if the
   Mac is lost, because the key is deliberately kept out of backups. macOS may say IronVault
   added a background item; that's the watchdog, so leave it on.
3. **Self-test.** Run:
   ```sh
   zsh ~/Downloads/ironvault/scripts/selftest.sh
   ```
   Touch ID asks once. It seals and opens test files, checks that a wrong key and a changed
   byte are both refused, and saves `selftest-result.txt`. **Until it passes, IronVault never
   deletes an original**: auto-sealing the folder stays off and Add Files keeps your originals.
   If anything fails, send that file.

## The menu bar

| Item | What it does |
|---|---|
| Dashboard… | Shows who asked to open vault files, what you allowed, and reads IronVault noticed. |
| *document* › Show | Brings an open document to the front. |
| *document* › Keep Open 15 More Minutes | Delays the wipe. |
| *document* › Close and Wipe | Saves any changes into the vault, then deletes the decrypted copy. |
| Close All Documents | The same for everything open. |
| Open a Vault File… | Pick sealed files to open. One Touch ID covers files picked together. |
| Add Files to Vault… | Seal files or folders, then delete or keep the originals. |
| Show Vault in Finder | Opens your IronVault folder. |
| Close Documents When Mac Sleeps or Locks | On by default. |
| Open at Login | On by default. |

## The Dashboard

Choose **Dashboard…** in the menu bar. When there's something new, the lock icon shows a
warning badge and you get a notification. It lists, for the last 7 days and beyond:

| Event | What it means |
|---|---|
| Opened | A vault file was opened after Touch ID. Shows which program asked: Finder for a double-click, or the chain of programs behind it, such as `open ← zsh ← node ← Terminal`. |
| Refused | Something asked to open a vault file and Touch ID was cancelled. |
| Read outside IronVault | A program read a sealed file directly. It only got encrypted data. |
| Open copy read by… | A program opened the decrypted copy of a document while it was open. Your document's own app is listed normally; command-line tools and AI apps are flagged. |
| Sealed | Files were added to the vault. |

**What it can and can't see.** Every request that goes through IronVault is recorded, with
your answer. Direct reads of sealed files are noticed within about 15 seconds, but macOS only
says which program it was if that program still has the file open; quick reads show as
"unknown". The checks of the decrypted copy run every 5 seconds, so a program that reads it
faster than that can be missed. Time Machine's reads during a backup aren't reported. Antivirus
scans can show up as unknown reads. IronVault can't see a program that asks macOS for an
administrator prompt on its own, without IronVault, which is why you should only approve prompts
that name IronVault and a file you chose.

The record is kept in `~/Library/Application Support/IronVault/activity.log`. An app running
as you could edit that file, so every entry is also written to macOS's system log, which it
can't erase:

```sh
log show --last 7d --predicate 'subsystem == "local.ironmountain.ironvault"'
```

From Terminal: `ironvault add FILE…`, `ironvault open FILE.ivault`, `ironvault list`,
`ironvault status` (the command lives in `/Library/IronVault/bin`). The command can seal files
but can't open them: only the app can, after Touch ID.

## How it works

- **Each file is encrypted separately** with its own key: X25519 key agreement, HKDF-SHA256 and
  AES-256-GCM, using Apple's CryptoKit. Any change to a sealed file, even one byte, is detected.
- **Sealing uses the vault's public key**, so adding files never asks for Touch ID.
- **Opening needs the private key**, which sits in a file only the system's root account can
  read. IronVault gets it through macOS's administrator prompt, for that one request only, and
  never stores it.
- **A decrypted copy lives in a private folder** (`~/Library/Caches/IronVault`, left out of
  Spotlight and Time Machine) only while the document is open.
- **A watchdog** run by the system every 15 seconds wipes any decrypted copies if the app isn't
  running (after a crash, say), never lets a copy live longer than 8 hours, and seals plain
  files left in the vault folder.
- **Nothing running as you can change IronVault.** The app, command, watchdog, public key and
  settings are all owned by root.

## What's guaranteed and what isn't

**Guaranteed by macOS:** a sealed file can't be read by any app running as you, AI or not.
Opening it takes your fingerprint or password, file by file.

**Not guaranteed, by any tool of this kind:**

- **An open document is readable.** While a file is open, its decrypted copy can be read by any
  app on your Mac, AI tools included. That's how the document's own app reads it. Only that one
  file is exposed, and only until it's wiped.
- **Apps keep their own copies.** Some apps keep autosaves, version history or caches of what
  they open (Apple's Versions, Office autorecovery, Quick Look thumbnails, Recent Items).
  Those copies are outside IronVault's reach.
- **Apps that can see your screen** (Screen Recording or Accessibility access, which some AI
  assistants ask for) can see an open document. Review them in System Settings › Privacy &
  Security.
- **The prompt is the permission.** If an AI tool asks IronVault to open a file, the prompt
  names it. Approving a prompt you didn't start, or giving an AI tool your password, opens it.
- **File names are visible.** Contents are sealed, but names like `Taxes 2025.pdf.ivault` can be
  seen. Give sensitive files plain names if that matters.
- **Sealed files can be deleted.** An app can't read them but could delete them. Keep
  `~/IronVault` in Time Machine; the backups stay sealed.
- **The Dashboard can miss quick reads**, and can't always name the program. See "What it can
  and can't see" above.
- **Files up to 2 GB.**
- **The prompt says "osascript".** That's the macOS tool IronVault uses to show the
  administrator prompt; IronVault's message, naming the file, appears under it. If your Mac
  shows only a password field there, the password does the same job.

### Optional: ask AI tools to stay out

These are rules the tools follow, not locks. For Claude Code, add to `~/.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "Read(~/IronVault/**)",
      "Read(~/Library/Caches/IronVault/**)",
      "Read(//Library/IronVault/**)"
    ]
  }
}
```

## Updating, recovery and removal

**Update:** run `install.sh` from a newer copy. It keeps your key and files, replaces the rest,
and asks you to run the self-test again before originals are deleted.

**Open files without IronVault** (new Mac, lost key file): reinstall IronVault on any Mac, then

```sh
/Library/IronVault/bin/ironvault recover ~/IronVault/"Taxes 2025.pdf.ivault" ~/Desktop
```

and type your recovery key when asked.

**Put your key back on a new Mac** so double-click works again. Do this before installing,
so the installer keeps your key instead of making a new one:

```sh
sudo mkdir -p /Library/IronVault/key && sudo chmod 700 /Library/IronVault/key
read -rs "?Recovery key: " K; printf '%s' "$K" | sudo tee /Library/IronVault/key/private.key >/dev/null; unset K
sudo chmod 400 /Library/IronVault/key/private.key && sudo chown -R root:wheel /Library/IronVault
zsh ~/Downloads/ironvault/install.sh     # finds your key and keeps it
```

**Uninstall:** `zsh ~/Downloads/ironvault/uninstall.sh`. It removes the app, watchdog, command
and key, and leaves your sealed files. After that only the recovery key opens them.

## What's in this folder

| Path | What it is |
|---|---|
| `install.sh` | Builds and installs, or updates. A failed build changes nothing. |
| `uninstall.sh` | Removes IronVault and keeps your sealed files. |
| `scripts/selftest.sh` | Proves sealing and opening work on your Mac, then turns on deleting originals. |
| `scripts/build-app.sh` | Builds into `./build` without installing. |
| `app/Sources/IronVaultCore` | Encryption, the file format and the vault folder logic. |
| `app/Sources/IronVault` | The menu bar app: Touch ID, opening, saving back, wiping. |
| `app/Sources/ironvault-cli` | The `ironvault` command and the watchdog. |
| `launchd/` | Runs the watchdog every 15 seconds. |

This was written without a Mac to build or run it on. The self-test exists to close that gap,
and IronVault won't delete any original until it passes.
