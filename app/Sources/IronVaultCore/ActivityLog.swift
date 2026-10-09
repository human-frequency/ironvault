import Foundation
import os

/// One line in the Dashboard.
public struct ActivityEvent: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable {
        case request          // something asked IronVault to open files
        case read             // a sealed file was read directly, outside IronVault
        case copyReader = "copy-reader"  // a program opened the decrypted copy of an open document
        case sealed           // files were added to the vault
    }
    public enum Outcome: String, Codable { case approved, denied, failed }

    public let time: Date
    public let kind: Kind
    /// Paths inside the vault folder, such as "Taxes 2025.pdf.ivault".
    public let files: [String]
    public let outcome: Outcome?
    /// The program behind it, as far as macOS lets IronVault see. nil when it can't tell.
    public let by: String?
    /// True for command-line tools and AI apps, which have no business reading your documents.
    public let unusual: Bool

    public init(time: Date = Date(), kind: Kind, files: [String], outcome: Outcome? = nil,
                by: String? = nil, unusual: Bool = false) {
        self.time = time; self.kind = kind; self.files = files
        self.outcome = outcome; self.by = by; self.unusual = unusual
    }

    public var id: String {
        "\(time.timeIntervalSince1970)|\(kind.rawValue)|\(files.joined(separator: ","))|\(by ?? "")|\(outcome?.rawValue ?? "")"
    }

    public var needsAttention: Bool {
        switch kind {
        case .request: return outcome != .approved
        case .read: return true
        case .copyReader: return unusual
        case .sealed: return false
        }
    }

    /// File names as people know them, without ".ivault".
    public var displayFiles: String {
        let names = files.map { name -> String in
            let last = (name as NSString).lastPathComponent
            return last.hasSuffix(".ivault") ? String(last.dropLast(7)) : last
        }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
}

/// The Dashboard's record, one JSON line per event in ~/Library/Application Support/IronVault/activity.log.
/// Every line is also written to macOS's system log, which apps running as you can't erase:
///   log show --last 7d --predicate 'subsystem == "local.ironmountain.ironvault"'
public enum ActivityLog {
    static let logger = Logger(subsystem: VaultConfig.bundleID, category: "activity")
    static let keepLines = 5000

    public static func fileURL(_ config: VaultConfig) -> URL {
        config.home.appendingPathComponent("Library/Application Support/IronVault/activity.log")
    }

    public static func append(_ event: ActivityEvent, config: VaultConfig) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        logger.log("\(String(decoding: line, as: UTF8.self), privacy: .public)")
        line.append(0x0A)
        let url = fileURL(config)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Newest first.
    public static func read(_ config: VaultConfig, limit: Int = 2000) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: fileURL(config)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).suffix(limit)
            .compactMap { try? decoder.decode(ActivityEvent.self, from: Data($0)) }
            .reversed()
    }

    /// Keeps the file from growing forever. The system log keeps its own copy.
    public static func trim(_ config: VaultConfig) {
        let url = fileURL(config)
        guard let data = try? Data(contentsOf: url), data.count > 2_000_000 else { return }
        let lines = data.split(separator: 0x0A).suffix(keepLines)
        var out = Data()
        for line in lines { out.append(contentsOf: line); out.append(0x0A) }
        try? out.write(to: url, options: .atomic)
    }

    public static func relativePath(_ url: URL, in config: VaultConfig) -> String {
        let base = config.vaultDir.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }
}
