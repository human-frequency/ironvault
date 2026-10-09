import CryptoKit
import Foundation

/// Settings written by install.sh into root-owned files, so nothing running as you can change them.
public struct VaultConfig {
    public static let rootDir = "/Library/IronVault"
    public static let configPath = "/Library/IronVault/config"
    public static let publicKeyPath = "/Library/IronVault/public.key"
    public static let privateKeyPath = "/Library/IronVault/key/private.key"
    public static let verifiedPath = "/Library/IronVault/verified"
    public static let bundleID = "local.ironmountain.ironvault"
    public static let appPath = "/Applications/IronVault.app"

    public let user: String
    public let home: URL
    public let vaultDir: URL
    /// How long a document stays decrypted after you open it or last change it.
    public let openMinutes: Int
    /// The longest any decrypted copy may exist, however often it's extended.
    public let maxOpenMinutes: Int

    public enum Failure: LocalizedError {
        case notInstalled, notRootOwned(String)
        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "IronVault isn't installed. Run install.sh."
            case .notRootOwned(let path): return "\(path) isn't owned by root. Reinstall IronVault."
            }
        }
    }

    public static func load() throws -> VaultConfig {
        guard FileManager.default.fileExists(atPath: configPath) else { throw Failure.notInstalled }
        try requireRootOwned(configPath)
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let user = values["VAULT_USER"], let home = values["VAULT_HOME"], let dir = values["VAULT_DIR"],
              !user.isEmpty, !home.isEmpty, !dir.isEmpty else { throw Failure.notInstalled }
        return VaultConfig(user: user,
                           home: URL(fileURLWithPath: home, isDirectory: true),
                           vaultDir: URL(fileURLWithPath: dir, isDirectory: true),
                           openMinutes: Int(values["OPEN_MINUTES"] ?? "") ?? 15,
                           maxOpenMinutes: Int(values["MAX_OPEN_MINUTES"] ?? "") ?? 480)
    }

    public static func requireRootOwned(_ path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0 else { throw Failure.notRootOwned(path) }
    }

    public func publicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Self.requireRootOwned(Self.publicKeyPath)
        return try VaultCrypto.publicKey(fromBase64: String(contentsOfFile: Self.publicKeyPath, encoding: .utf8))
    }

    /// True once the self-test has proven a full seal-and-open round trip on this Mac.
    /// Until then nothing deletes your originals.
    public var isVerified: Bool {
        FileManager.default.fileExists(atPath: Self.verifiedPath) && (try? Self.requireRootOwned(Self.verifiedPath)) != nil
    }

    /// Where decrypted copies live while a document is open. ".noindex" keeps Spotlight out,
    /// and ~/Library/Caches is left out of Time Machine.
    public var openCopiesDir: URL {
        home.appendingPathComponent("Library/Caches/IronVault/open.noindex", isDirectory: true)
    }
}
