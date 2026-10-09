import CryptoKit
import Foundation

public enum VaultFiles {
    public enum Failure: LocalizedError {
        case zipFailed(String), tooLarge(String)
        public var errorDescription: String? {
            switch self {
            case .zipFailed(let name): return "Couldn't package \(name)."
            case .tooLarge(let name): return "\(name) is larger than 2 GB, which IronVault can't hold yet."
            }
        }
    }

    static let maxBytes = 2_000_000_000
    static let fm = FileManager.default

    // MARK: Sealing

    /// Encrypts a file or package into `directory` as "name.ext.ivault" and checks what landed on disk.
    /// The original is left alone; callers delete it only after this returns.
    @discardableResult
    public static func seal(_ source: URL, into directory: URL,
                            publicKey: Curve25519.KeyAgreement.PublicKey) throws -> URL {
        let (plaintext, kind) = try readPlain(source)
        let sealed = try VaultCrypto.seal(plaintext, kind: kind, to: publicKey)
        let destination = uniqueURL(directory.appendingPathComponent(source.lastPathComponent + "." + VaultCrypto.fileExtension))
        try sealed.write(to: destination, options: .atomic)
        guard (try? Data(contentsOf: destination)) == sealed else {
            try? fm.removeItem(at: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Replaces an existing .ivault file with a new sealed copy of `plain`. Used to save edits back.
    public static func reseal(_ plain: URL, over target: URL,
                              publicKey: Curve25519.KeyAgreement.PublicKey) throws {
        let (plaintext, kind) = try readPlain(plain)
        let sealed = try VaultCrypto.seal(plaintext, kind: kind, to: publicKey)
        try sealed.write(to: target, options: .atomic)
        guard (try? Data(contentsOf: target)) == sealed else { throw CocoaError(.fileWriteUnknown) }
    }

    static func readPlain(_ url: URL) throws -> (Data, VaultCrypto.Kind) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            let zip = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? fm.removeItem(at: zip) }
            guard run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, zip.path]) == 0 else {
                throw Failure.zipFailed(url.lastPathComponent)
            }
            let data = try Data(contentsOf: zip)
            guard data.count <= maxBytes else { throw Failure.tooLarge(url.lastPathComponent) }
            return (data, .package)
        }
        guard (values.fileSize ?? 0) <= maxBytes else { throw Failure.tooLarge(url.lastPathComponent) }
        return (try Data(contentsOf: url), .file)
    }

    // MARK: Opening

    /// Decrypts one .ivault file into a fresh private folder and returns the document's URL.
    public static func extract(_ source: URL, with privateKey: Curve25519.KeyAgreement.PrivateKey,
                               into parent: URL) throws -> (url: URL, kind: VaultCrypto.Kind) {
        let sealed = try Data(contentsOf: source)
        let (kind, plaintext) = try VaultCrypto.open(sealed, with: privateKey)
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = plainName(of: source)
        let target = folder.appendingPathComponent(name)
        switch kind {
        case .file:
            try plaintext.write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        case .package:
            let zip = folder.appendingPathComponent(".package.zip")
            try plaintext.write(to: zip)
            defer { try? fm.removeItem(at: zip) }
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0,
                  fm.fileExists(atPath: target.path) else { throw Failure.zipFailed(name) }
        }
        return (target, kind)
    }

    public static func plainName(of sealed: URL) -> String {
        let name = sealed.lastPathComponent
        let suffix = "." + VaultCrypto.fileExtension
        return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
    }

    /// Size and newest modification time, for files and package folders, to notice edits.
    public static func signature(of url: URL) -> String {
        var newest = Date.distantPast
        var total = 0
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        func add(_ item: URL) {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { return }
            if let d = v.contentModificationDate, d > newest { newest = d }
            total += v.fileSize ?? 0
        }
        add(url)
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
           let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let item as URL in walker { add(item) }
        }
        return "\(newest.timeIntervalSince1970)|\(total)"
    }

    // MARK: The vault folder

    /// Seals any plain files or packages that were dropped into the vault folder, then deletes
    /// the plain originals. Skips anything changed in the last few seconds (still being copied).
    public static func sweep(_ config: VaultConfig, publicKey: Curve25519.KeyAgreement.PublicKey,
                             settle: TimeInterval = 5) -> (sealed: [String], failed: [String]) {
        var sealed: [String] = [], failed: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: config.vaultDir, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        let cutoff = Date().addingTimeInterval(-settle)
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let isPackage = v.isPackage == true
            if v.isDirectory == true && !isPackage { continue }            // an ordinary folder: look inside
            if url.pathExtension == VaultCrypto.fileExtension { continue }  // already sealed
            if signatureDate(url) > cutoff { continue }                    // still arriving
            do {
                try seal(url, into: url.deletingLastPathComponent(), publicKey: publicKey)
                try fm.removeItem(at: url)
                sealed.append(url.lastPathComponent)
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (sealed, failed)
    }

    static func signatureDate(_ url: URL) -> Date {
        let parts = signature(of: url).split(separator: "|")
        return Date(timeIntervalSince1970: TimeInterval(parts.first.map(String.init) ?? "") ?? 0)
    }

    public static func listSealed(_ config: VaultConfig) -> [URL] {
        guard let walker = fm.enumerator(at: config.vaultDir, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == VaultCrypto.fileExtension }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func uniqueURL(_ url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension()           // "name.ext"
        let inner = base.pathExtension                   // "ext"
        let stem = base.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = inner.isEmpty ? "\(stem) \(n).\(VaultCrypto.fileExtension)"
                                     : "\(stem) \(n).\(inner).\(VaultCrypto.fileExtension)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: Helpers

    @discardableResult
    public static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a tool and returns what it printed.
    public static func capture(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes every decrypted copy. Used on lock, sleep, quit, and by the watchdog.
    public static func wipeOpenCopies(_ config: VaultConfig, olderThan age: TimeInterval? = nil) {
        let dir = config.openCopiesDir
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for item in items {
            if let age = age {
                let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                guard Date().timeIntervalSince(created) > age else { continue }
            }
            try? fm.removeItem(at: item)
        }
    }
}
