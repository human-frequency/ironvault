import AppKit
import CryptoKit
import Foundation
#if canImport(IronVaultCore)
import IronVaultCore   // separate module when built with Swift's package manager
#endif
import UniformTypeIdentifiers

/// Opens one sealed document at a time after Touch ID, saves your edits back into the sealed
/// file while it's open, and wipes the decrypted copy when you close it, when time runs out,
/// or when the Mac sleeps or locks.
@MainActor
final class VaultController: ObservableObject {
    static let shared = VaultController()

    struct OpenDoc: Identifiable {
        let id = UUID()
        let name: String
        let source: URL      // the .ivault file
        let plain: URL       // the decrypted copy
        let folder: URL      // private folder holding the copy
        let openedAt: Date
        var closesAt: Date
        var savedSignature: String
        var seenReaders: Set<String> = []
    }

    @Published private(set) var docs: [OpenDoc] = []
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var now = Date()
    @Published private(set) var config: VaultConfig?
    @Published private(set) var sealedCount = 0
    @Published private(set) var unseenAlerts = 0
    @Published private(set) var opensAtLogin = LoginItem.isEnabled
    @Published var closeOnSleep = true {
        didSet { UserDefaults.standard.set(closeOnSleep, forKey: "closeOnSleep") }
    }

    private var pending: [URL] = []
    private var pendingRequesters: [String] = []
    private var lastLogCheck = Date.distantPast
    private var lastNotifiedAlert: Date
    private var alertsSeenAt: Date {
        get { UserDefaults.standard.object(forKey: "alertsSeenAt") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "alertsSeenAt") }
    }
    private var pendingTask: Task<Void, Never>?
    private var lastSweep = Date.distantPast
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        lastNotifiedAlert = Date()
        closeOnSleep = UserDefaults.standard.object(forKey: "closeOnSleep") as? Bool ?? true
        if !UserDefaults.standard.bool(forKey: "didSetUpLogin") {
            UserDefaults.standard.set(true, forKey: "didSetUpLogin")
            try? LoginItem.enable()
            opensAtLogin = LoginItem.isEnabled
        }
        config = try? VaultConfig.load()
        if let config = self.config {
            // Copies left by a crash or forced quit are wiped before anything else happens.
            VaultFiles.wipeOpenCopies(config)
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willPowerOffNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.macWentAway() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.macWentAway() }
        })
    }

    // MARK: Menu text

    var isInstalled: Bool { config != nil }
    var isVerified: Bool { config?.isVerified ?? false }

    var statusLine: String {
        guard isInstalled else { return "IronVault isn't installed. Run install.sh." }
        if isBusy { return "Waiting for Touch ID…" }
        if docs.isEmpty { return "Vault sealed · \(sealedCount) file\(sealedCount == 1 ? "" : "s")" }
        return "\(docs.count) document\(docs.count == 1 ? "" : "s") open"
    }

    func countdown(_ doc: OpenDoc) -> String {
        let t = max(0, Int(doc.closesAt.timeIntervalSince(now).rounded(.up)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Opening

    /// Files opened from Finder, the menu or the ironvault command all arrive here.
    /// Requests that arrive together share one Touch ID prompt.
    func requestOpen(_ urls: [URL], requester: String? = nil) {
        if let requester = requester, !urls.isEmpty, !pendingRequesters.contains(requester) { pendingRequesters.append(requester) }
        let sealed = urls.filter { $0.pathExtension == VaultCrypto.fileExtension }
        if sealed.count < urls.count { lastError = "IronVault only opens .ivault files." }
        for url in sealed {
            if let doc = docs.first(where: { $0.source.standardizedFileURL == url.standardizedFileURL }) {
                NSWorkspace.shared.open(doc.plain)       // already open: just bring it forward
            } else if !pending.contains(url) {
                pending.append(url)
            }
        }
        guard !pending.isEmpty, pendingTask == nil else { return }
        pendingTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self.openPending()
            self.pendingTask = nil
            if !self.pending.isEmpty { self.requestOpen([]) }
        }
    }

    private func openPending() async {
        let batch = pending
        pending = []
        let requester = pendingRequesters.isEmpty ? nil : pendingRequesters.joined(separator: "; ")
        pendingRequesters = []
        guard let config = self.config else { lastError = VaultConfig.Failure.notInstalled.localizedDescription; return }
        let names = batch.map(VaultFiles.plainName(of:))
        let reason: String
        if names.count == 1 {
            reason = "IronVault wants to open “\(names[0])”."
        } else {
            let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
            reason = "IronVault wants to open \(names.count) documents: \(shown)."
        }

        isBusy = true
        let outcome = await KeyBroker.fetchPrivateKey(reason: reason)
        isBusy = false
        let files = batch.map { ActivityLog.relativePath($0, in: config) }
        let key: Curve25519.KeyAgreement.PrivateKey
        switch outcome {
        case .cancelled:
            log(ActivityEvent(kind: .request, files: files, outcome: .denied, by: requester,
                              unusual: requester.map(AccessMonitor.isUnusual) ?? false))
            return
        case .failed(let message):
            log(ActivityEvent(kind: .request, files: files, outcome: .failed, by: requester))
            lastError = "Couldn't get permission. \(message)"
            return
        case .granted(let k):
            log(ActivityEvent(kind: .request, files: files, outcome: .approved, by: requester,
                              unusual: requester.map(AccessMonitor.isUnusual) ?? false))
            key = k
        }

        lastError = nil
        prepareOpenCopiesFolder(config)
        for source in batch {
            do {
                let (plain, _) = try VaultFiles.extract(source, with: key, into: config.openCopiesDir)
                let doc = OpenDoc(name: VaultFiles.plainName(of: source), source: source, plain: plain,
                                  folder: plain.deletingLastPathComponent(), openedAt: Date(),
                                  closesAt: Date().addingTimeInterval(TimeInterval(config.openMinutes * 60)),
                                  savedSignature: VaultFiles.signature(of: plain))
                docs.append(doc)
                NSWorkspace.shared.open(plain)
            } catch {
                lastError = "Couldn't open \(source.lastPathComponent). \(error.localizedDescription)"
            }
        }
    }

    private func prepareOpenCopiesFolder(_ config: VaultConfig) {
        let fm = FileManager.default
        let parent = config.openCopiesDir.deletingLastPathComponent()
        try? fm.createDirectory(at: config.openCopiesDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.openCopiesDir.path)
    }

    // MARK: Closing

    func show(_ doc: OpenDoc) { NSWorkspace.shared.open(doc.plain) }

    func extend(_ doc: OpenDoc) {
        guard let config = self.config, let i = docs.firstIndex(where: { $0.id == doc.id }) else { return }
        let cap = docs[i].openedAt.addingTimeInterval(TimeInterval(config.maxOpenMinutes * 60))
        docs[i].closesAt = min(max(docs[i].closesAt, Date()).addingTimeInterval(15 * 60), cap)
    }

    /// Saves any edits back into the sealed file, then deletes the decrypted copy.
    /// If saving fails, the copy is kept and you see why, so no edit is ever lost silently.
    @discardableResult
    func close(_ doc: OpenDoc) -> Bool {
        guard let i = docs.firstIndex(where: { $0.id == doc.id }) else { return true }
        guard saveBack(at: i) else { return false }
        try? FileManager.default.removeItem(at: docs[i].folder)
        docs.remove(at: i)
        return true
    }

    func closeAll() {
        for doc in docs { close(doc) }
        if docs.isEmpty, let config = self.config { VaultFiles.wipeOpenCopies(config) }
    }

    /// Re-seals the copy if it changed since the last save. Returns false only if saving failed.
    private func saveBack(at i: Int) -> Bool {
        let doc = docs[i]
        guard FileManager.default.fileExists(atPath: doc.plain.path) else { return true }
        let signature = VaultFiles.signature(of: doc.plain)
        guard signature != doc.savedSignature else { return true }
        do {
            guard let key = try config?.publicKey() else { return false }
            try VaultFiles.reseal(doc.plain, over: doc.source, publicKey: key)
            docs[i].savedSignature = signature
            return true
        } catch {
            lastError = "Couldn't save changes to \(doc.name). The open copy is kept. \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Adding

    func addFiles() {
        guard let config = self.config else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Add to IronVault"
        panel.prompt = "Seal"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var deleteOriginals = false
        if config.isVerified {
            let alert = NSAlert()
            alert.messageText = "Seal \(panel.urls.count) item\(panel.urls.count == 1 ? "" : "s") into IronVault?"
            alert.informativeText = "Deleting the originals leaves only the sealed copies, which need Touch ID to open."
            alert.addButton(withTitle: "Seal and Delete Originals")
            alert.addButton(withTitle: "Seal and Keep Originals")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: deleteOriginals = true
            case .alertSecondButtonReturn: deleteOriginals = false
            default: return
            }
        }

        do {
            let key = try config.publicKey()
            var sealed = 0
            for url in panel.urls {
                do {
                    try VaultFiles.seal(url, into: config.vaultDir, publicKey: key)
                    if deleteOriginals { try FileManager.default.removeItem(at: url) }
                    sealed += 1
                } catch {
                    lastError = "Couldn't seal \(url.lastPathComponent). \(error.localizedDescription)"
                }
            }
            if sealed > 0 {
                KeyBroker.notify("Sealed \(sealed) item\(sealed == 1 ? "" : "s")")
                log(ActivityEvent(kind: .sealed, files: panel.urls.map(\.lastPathComponent), by: "Add Files to Vault"))
            }
        } catch {
            lastError = error.localizedDescription
        }
        refreshCount()
    }

    func chooseFileToOpen() {
        guard let config = self.config else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Open from IronVault"
        panel.directoryURL = config.vaultDir
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: VaultCrypto.fileExtension) ?? .data]
        guard panel.runModal() == .OK else { return }
        requestOpen(panel.urls, requester: "You, from the IronVault menu")
    }

    func showVaultInFinder() {
        guard let config = self.config else { return }
        NSWorkspace.shared.open(config.vaultDir)
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try LoginItem.enable() } else { try LoginItem.disable() }
        } catch {
            lastError = "Open at Login failed. \(error.localizedDescription)"
        }
        opensAtLogin = LoginItem.isEnabled
    }

    // MARK: Timers and system events

    private func tick() {
        now = Date()
        if config == nil { config = try? VaultConfig.load() }
        guard let config = self.config else { return }

        // Save edits back as they happen; closing time moves out while you keep working.
        for i in docs.indices {
            let before = docs[i].savedSignature
            if saveBack(at: i), docs[i].savedSignature != before {
                let cap = docs[i].openedAt.addingTimeInterval(TimeInterval(config.maxOpenMinutes * 60))
                docs[i].closesAt = min(max(docs[i].closesAt, now.addingTimeInterval(TimeInterval(config.openMinutes * 60))), cap)
            }
        }
        for doc in docs where now >= doc.closesAt {
            if close(doc) { KeyBroker.notify("Closed and wiped \(doc.name)") }
        }

        if now.timeIntervalSince(lastSweep) >= 10 {
            lastSweep = now
            if config.isVerified, let key = try? config.publicKey() {
                let result = VaultFiles.sweep(config, publicKey: key)
                if !result.sealed.isEmpty {
                    log(ActivityEvent(kind: .sealed, files: result.sealed, by: "IronVault folder"))
                    KeyBroker.notify("Sealed \(result.sealed.count) new item\(result.sealed.count == 1 ? "" : "s") in the vault")
                }
                if let first = result.failed.first { lastError = "Couldn't seal \(first)" }
            }
            refreshCount()
        }

        if now.timeIntervalSince(lastLogCheck) >= 5 {
            lastLogCheck = now
            watchOpenCopies(config)
            checkAlerts(config)
        }
    }

    // MARK: Dashboard

    func log(_ event: ActivityEvent) {
        guard let config = self.config else { return }
        ActivityLog.append(event, config: config)
        if event.needsAttention { checkAlerts(config) }
    }

    func events() -> [ActivityEvent] {
        guard let config = self.config else { return [] }
        return ActivityLog.read(config)
    }

    func markAlertsSeen() {
        alertsSeenAt = Date()
        unseenAlerts = 0
    }

    /// Counts alerts you haven't looked at, and tells you about new ones.
    private func checkAlerts(_ config: VaultConfig) {
        let fresh = ActivityLog.read(config, limit: 500).filter { $0.needsAttention && $0.time > alertsSeenAt }
        unseenAlerts = fresh.count
        let newest = fresh.filter { $0.time > lastNotifiedAlert }
        guard let latest = newest.first else { return }
        lastNotifiedAlert = latest.time
        KeyBroker.notify(newest.count == 1 ? DashboardText.title(latest) : "\(newest.count) new alerts. Open the Dashboard to see them.")
    }

    /// Notes every program that opens the decrypted copy of an open document. The first is
    /// usually the document's own app; command-line tools and AI apps are flagged.
    private func watchOpenCopies(_ config: VaultConfig) {
        let folders = docs.map { (id: $0.id, path: $0.folder.path) }
        guard !folders.isEmpty else { return }
        Task {
            // lsof takes a moment, so it runs off the main thread.
            let found = await Task.detached { () -> [(id: UUID, openers: [(pid: Int32, name: String)])] in
                folders.map { (id: $0.id, openers: AccessMonitor.openers(of: $0.path)) }
            }.value
            for entry in found {
                guard let i = self.docs.firstIndex(where: { $0.id == entry.id }) else { continue }
                for opener in entry.openers where !self.docs[i].seenReaders.contains(opener.name) {
                    self.docs[i].seenReaders.insert(opener.name)
                    let unusual = AccessMonitor.isUnusual(opener.name)
                    let chain = unusual ? (AccessMonitor.processChain(opener.pid) ?? opener.name) : opener.name
                    self.log(ActivityEvent(kind: .copyReader, files: [ActivityLog.relativePath(self.docs[i].source, in: config)],
                                      by: chain, unusual: unusual))
                }
            }
        }
    }

    private func refreshCount() {
        if let config = self.config { sealedCount = VaultFiles.listSealed(config).count }
    }

    private func macWentAway() {
        guard closeOnSleep, !docs.isEmpty else { return }
        closeAll()
    }
}
