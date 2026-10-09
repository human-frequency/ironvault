import CryptoKit
import Foundation

/// One encrypted file, `name.ext.ivault`:
///
///     "IRONVLT1"  8 bytes   magic and format version
///     kind        1 byte    0 = file, 1 = package folder (zipped with ditto)
///     ephemeral   32 bytes  X25519 public key made for this file only
///     sealed      rest      AES-256-GCM: 12-byte nonce, ciphertext, 16-byte tag
///
/// The AES key comes from X25519(ephemeral, vault key) through HKDF-SHA256. Sealing needs only
/// the vault's public key, so adding files never asks for Touch ID. Opening needs the private
/// key, which only root can read. The header is authenticated, so changing any byte fails.
public enum VaultCrypto {
    public static let magic = Data("IRONVLT1".utf8)
    public static let fileExtension = "ivault"
    static let info = Data("IronVault file v1".utf8)
    static let headerSize = 8 + 1 + 32

    public enum Kind: UInt8 { case file = 0, package = 1 }

    public enum Failure: LocalizedError {
        case notAVaultFile, wrongKeyOrDamaged, badKey
        public var errorDescription: String? {
            switch self {
            case .notAVaultFile: return "This isn't an IronVault file."
            case .wrongKeyOrDamaged: return "This file is damaged or was sealed with a different vault key."
            case .badKey: return "The vault key is not valid."
            }
        }
    }

    public static func seal(_ plaintext: Data, kind: Kind, to publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var header = magic
        header.append(kind.rawValue)
        header.append(ephemeral.publicKey.rawRepresentation)
        let key = try fileKey(secret: ephemeral.sharedSecretFromKeyAgreement(with: publicKey),
                              header: header, recipient: publicKey)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw Failure.wrongKeyOrDamaged }
        return header + combined
    }

    public static func open(_ sealed: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> (kind: Kind, plaintext: Data) {
        let (kind, ephemeral) = try readHeader(sealed)
        let header = sealed.prefix(headerSize)
        let key = try fileKey(secret: privateKey.sharedSecretFromKeyAgreement(with: ephemeral),
                              header: Data(header), recipient: privateKey.publicKey)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(headerSize))
            return (kind, try AES.GCM.open(box, using: key, authenticating: header))
        } catch {
            throw Failure.wrongKeyOrDamaged
        }
    }

    /// Checks the header only, without any key.
    public static func isVaultFile(_ data: Data) -> Bool {
        (try? readHeader(data)) != nil
    }

    static func readHeader(_ data: Data) throws -> (Kind, Curve25519.KeyAgreement.PublicKey) {
        guard data.count > headerSize + 28, data.prefix(8) == magic,
              let kind = Kind(rawValue: data[data.startIndex + 8]),
              let ephemeral = try? Curve25519.KeyAgreement.PublicKey(
                  rawRepresentation: data.subdata(in: (data.startIndex + 9)..<(data.startIndex + headerSize)))
        else { throw Failure.notAVaultFile }
        return (kind, ephemeral)
    }

    static func fileKey(secret: SharedSecret, header: Data, recipient: Curve25519.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: header + recipient.rawRepresentation,
                                       sharedInfo: info,
                                       outputByteCount: 32)
    }

    // MARK: Keys, stored as one line of base64

    public static func newPrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    public static func privateKey(fromBase64 text: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { throw Failure.badKey }
        return key
    }

    public static func publicKey(fromBase64 text: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { throw Failure.badKey }
        return key
    }
}
