import CryptoKit
import Foundation
#if canImport(IronVaultCore)
import IronVaultCore   // separate module when built with Swift's package manager
#endif

/// Gets the vault's private key for one request, after macOS's administrator prompt
/// (Touch ID, or your password). A new osascript process each time, so no earlier approval
/// is ever reused. The key is used for the files in this request and then dropped.
enum KeyBroker {
    enum Outcome {
        case granted(Curve25519.KeyAgreement.PrivateKey)
        case cancelled
        case failed(String)
    }

    static func fetchPrivateKey(reason: String) async -> Outcome {
        let script = "do shell script \"/bin/cat \(VaultConfig.privateKeyPath)\" with prompt \"\(appleScriptEscaped(reason))\" with administrator privileges"
        let (status, output, error) = await Task.detached { () -> (Int32, Data, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, Data(), error.localizedDescription) }
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, o, String(decoding: e, as: UTF8.self))
        }.value
        if status != 0 {
            return error.contains("-128") ? .cancelled : .failed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var text = String(decoding: output, as: UTF8.self)
        defer { text = "" }
        do { return .granted(try VaultCrypto.privateKey(fromBase64: text)) } catch { return .failed(error.localizedDescription) }
    }

    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func notify(_ message: String) {
        let script = "display notification \"\(appleScriptEscaped(message))\" with title \"IronVault\""
        Task.detached { _ = VaultFiles.run("/usr/bin/osascript", ["-e", script]) }
    }
}
