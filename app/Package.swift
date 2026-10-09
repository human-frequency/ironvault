// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IronVault",
    platforms: [.macOS(.v13)],
    targets: [
        // Encryption, file format, config and the open-copy folder. Shared by the app and the command.
        .target(name: "IronVaultCore", path: "Sources/IronVaultCore"),
        // The menu bar app: the only thing that can decrypt, and only after Touch ID.
        .executableTarget(name: "IronVault", dependencies: ["IronVaultCore"], path: "Sources/IronVault"),
        // The `ironvault` command: add files, list, recover, and the watchdog's sweep.
        .executableTarget(name: "ironvault-cli", dependencies: ["IronVaultCore"], path: "Sources/ironvault-cli"),
    ]
)
