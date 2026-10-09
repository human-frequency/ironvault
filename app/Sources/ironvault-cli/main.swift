import CryptoKit
import Foundation
#if canImport(IronVaultCore)
import IronVaultCore   // separate module when built with Swift's package manager
#endif

// The `ironvault` command, installed root-owned at /Library/IronVault/bin/ironvault.
// It can seal files and list the vault. It cannot open anything: only the IronVault app
// can, after Touch ID. (`recover` is the exception, and needs your recovery key typed in.)

let usage = """
Usage:
  ironvault add [--keep] FILE...   Seal files into the vault (originals are deleted unless --keep)
  ironvault open FILE.ivault       Open with IronVault (asks for Touch ID)
  ironvault list                   List sealed files
  ironvault status                 Show the vault folder and open documents
  ironvault recover FILE.ivault [FOLDER]
                                   Decrypt with your recovery key (for a new Mac or a restore)
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func loadConfig() -> VaultConfig {
    do { return try VaultConfig.load() } catch { fail(error.localizedDescription) }
}

func loadPublicKey(_ config: VaultConfig) -> Curve25519.KeyAgreement.PublicKey {
    do { return try config.publicKey() } catch { fail(error.localizedDescription) }
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "status" : args.removeFirst()

switch command {
case "add":
    let config = loadConfig()
    let key = loadPublicKey(config)
    let keep = args.contains("--keep")
    let files = args.filter { $0 != "--keep" }
    if files.isEmpty { fail(usage, code: 2) }
    if !keep && !config.isVerified {
        fail("Run the self-test first (scripts/selftest.sh). Until it passes, use --keep so your originals stay.")
    }
    var failures = 0
    for path in files {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        do {
            let sealed = try VaultFiles.seal(url, into: config.vaultDir, publicKey: key)
            if !keep { try FileManager.default.removeItem(at: url) }
            print("Sealed \(url.lastPathComponent) → \(sealed.lastPathComponent)\(keep ? " (original kept)" : "")")
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("Couldn't seal \(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }
    if files.count > failures {
        ActivityLog.append(ActivityEvent(kind: .sealed, files: files.map { URL(fileURLWithPath: $0).lastPathComponent },
                                         by: "ironvault add"), config: config)
    }
    exit(failures == 0 ? 0 : 1)

case "open":
    guard !args.isEmpty else { fail(usage, code: 2) }
    let status = VaultFiles.run("/usr/bin/open", ["-a", VaultConfig.appPath] + args)
    exit(status)

case "list":
    let config = loadConfig()
    let base = config.vaultDir.path + "/"
    for url in VaultFiles.listSealed(config) {
        print(url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path)
    }

case "_readcheck":
    // Used by the self-test: does this Mac record when a file is read?
    guard let path = args.first else { fail(usage, code: 2) }
    print(AccessMonitor.readsAreRecorded(at: path) ? "yes" : "no")

case "status":
    let config = loadConfig()
    let count = VaultFiles.listSealed(config).count
    let open = (try? FileManager.default.contentsOfDirectory(atPath: config.openCopiesDir.path))?.count ?? 0
    print("Vault folder: \(config.vaultDir.path)")
    print("Sealed files: \(count)")
    print("Documents open right now: \(open)")
    print(config.isVerified ? "Self-test: passed" : "Self-test: not run yet (scripts/selftest.sh)")

case "sweep":
    let config = loadConfig()
    guard config.isVerified else { exit(0) }
    let result = VaultFiles.sweep(config, publicKey: loadPublicKey(config))
    result.sealed.forEach { print("Sealed \($0)") }
    result.failed.forEach { FileHandle.standardError.write(Data("Couldn't seal \($0)\n".utf8)) }

case "recover":
    guard let path = args.first else { fail(usage, code: 2) }
    let source = URL(fileURLWithPath: path).standardizedFileURL
    let destination = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
    var keyText: String
    if isatty(STDIN_FILENO) != 0 {
        guard let typed = getpass("Recovery key: ") else { fail("No key entered.") }
        keyText = String(cString: typed)
    } else {
        keyText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    do {
        let key = try VaultCrypto.privateKey(fromBase64: keyText)
        keyText = ""
        let (url, _) = try VaultFiles.extract(source, with: key, into: destination)
        // extract makes a private subfolder; move the result up next to where you asked for it.
        let final = destination.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: final.path) else {
            print("Recovered to \(url.path) (a file named \(url.lastPathComponent) already exists here)")
            exit(0)
        }
        try FileManager.default.moveItem(at: url, to: final)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        print("Recovered \(final.path)")
    } catch {
        fail(error.localizedDescription)
    }

// --- Used by install.sh, the self-test and the watchdog ------------------------

case "_keygen":
    // Prints a new private key (base64). install.sh pipes it straight into the root-only file.
    print(VaultCrypto.newPrivateKey().rawRepresentation.base64EncodedString())

case "_pubkey":
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    do { print(try VaultCrypto.privateKey(fromBase64: text).publicKey.rawRepresentation.base64EncodedString()) }
    catch { fail(error.localizedDescription) }

case "_watchdog":
    // Run every 15 seconds by launchd (as you, not as root). Backstop for the app:
    // wipes decrypted copies when the app isn't running or a copy is too old,
    // then seals anything left in the vault folder in plain form.
    let config = loadConfig()
    let appRunning = VaultFiles.run("/usr/bin/pgrep", ["-x", "-u", config.user, "IronVault"]) == 0
    if appRunning {
        VaultFiles.wipeOpenCopies(config, olderThan: TimeInterval(config.maxOpenMinutes * 60))
    } else {
        VaultFiles.wipeOpenCopies(config)
    }
    if config.isVerified, let key = try? config.publicKey() {
        let result = VaultFiles.sweep(config, publicKey: key)
        if !result.sealed.isEmpty {
            ActivityLog.append(ActivityEvent(kind: .sealed, files: result.sealed, by: "IronVault folder"), config: config)
        }
    }
    // Reads of sealed files outside IronVault, for the Dashboard. IronVault's own approved
    // opens are left out.
    var ownOpens: [String: Date] = [:]
    for event in ActivityLog.read(config, limit: 300) where event.kind == .request && event.outcome == .approved {
        for file in event.files where ownOpens[file] == nil { ownOpens[file] = event.time }
    }
    for event in AccessMonitor.scan(config, ownOpens: ownOpens) {
        ActivityLog.append(event, config: config)
    }
    ActivityLog.trim(config)

default:
    fail(usage, code: 2)
}
