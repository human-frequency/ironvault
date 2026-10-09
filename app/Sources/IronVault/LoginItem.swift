import Foundation

/// Open at Login, done the way every macOS version since 10.x understands: a small launch
/// agent in ~/Library/LaunchAgents that asks macOS to open IronVault when you log in.
/// (The newer login item API needs macOS 13, and IronVault also runs on macOS 12.)
enum LoginItem {
    static let label = "local.ironmountain.ironvault"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Takes effect at your next login. Nothing is started now, so no second copy opens.
    static func enable() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", VaultConfig.appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    static func disable() throws {
        guard isEnabled else { return }
        try FileManager.default.removeItem(at: plistURL)
    }
}
