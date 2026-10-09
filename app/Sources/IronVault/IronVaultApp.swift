import AppKit
import Combine
#if canImport(IronVaultCore)
import IronVaultCore   // separate module when built with Swift's package manager
#endif

@main
enum IronVaultMain {
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate             // NSApplication only keeps a weak reference
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu(vault: VaultController.shared)
    }

    /// Double-clicking a .ivault file in Finder, or `ironvault open`, lands here.
    func application(_ application: NSApplication, open urls: [URL]) {
        VaultController.shared.requestOpen(urls, requester: requester())
    }

    /// Which program sent the "open these files" request: Finder for a double-click, or
    /// whatever ran `open` or `ironvault open`. Best effort: a program that has already
    /// exited can't be named.
    private func requester() -> String? {
        let senderPID = AEKeyword(0x7370_6964)   // 'spid'
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: senderPID)?.int32Value, pid > 0 else { return nil }
        return AccessMonitor.processChain(pid)
            ?? NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// Quitting saves edits back and wipes every decrypted copy.
    func applicationWillTerminate(_ notification: Notification) {
        VaultController.shared.closeAll()
    }
}

/// The lock in the menu bar. Plain AppKit, so it works on macOS 12 as well as later versions.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    /// Wraps a menu action so each item can carry its own closure.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private let vault: VaultController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var changes: AnyCancellable?
    private var liveTimer: Timer?
    private var statusItem: NSMenuItem?
    private var docItems: [(id: UUID, item: NSMenuItem)] = []

    init(vault: VaultController) {
        self.vault = vault
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateIcon()
        changes = vault.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new values are stored.
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    private func updateIcon() {
        let name = vault.unseenAlerts > 0 ? "lock.trianglebadge.exclamationmark.fill"
                 : vault.docs.isEmpty ? "lock.fill" : "lock.open.fill"
        guard item.button?.image?.accessibilityDescription != name else { return }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        image?.isTemplate = true
        item.button?.image = image
    }

    // MARK: Building the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        docItems = []

        statusItem = info(vault.statusLine)
        menu.addItem(statusItem!)
        if vault.isInstalled && !vault.isVerified {
            menu.addItem(info("Run the self-test to finish setup."))
        }
        if let error = vault.lastError {
            menu.addItem(info(error))
        }
        let alerts = vault.unseenAlerts
        menu.addItem(button(alerts > 0 ? "Dashboard… (\(alerts) new alert\(alerts == 1 ? "" : "s"))" : "Dashboard…",
                            key: "d", enabled: vault.isInstalled) { [vault] in DashboardWindow.show(vault) })
        menu.addItem(.separator())

        if !vault.docs.isEmpty {
            for doc in vault.docs {
                let sub = NSMenu()
                sub.autoenablesItems = false
                sub.addItem(button("Show") { [vault] in vault.show(doc) })
                sub.addItem(button("Keep Open 15 More Minutes") { [vault] in vault.extend(doc) })
                sub.addItem(button("Close and Wipe") { [vault] in _ = vault.close(doc) })
                let docItem = NSMenuItem(title: docTitle(doc), action: nil, keyEquivalent: "")
                docItem.submenu = sub
                menu.addItem(docItem)
                docItems.append((id: doc.id, item: docItem))
            }
            menu.addItem(button("Close All Documents", key: "l") { [vault] in vault.closeAll() })
            menu.addItem(.separator())
        }

        menu.addItem(button("Open a Vault File…", enabled: vault.isInstalled && !vault.isBusy) { [vault] in
            vault.chooseFileToOpen()
        })
        menu.addItem(button("Add Files to Vault…", enabled: vault.isInstalled) { [vault] in vault.addFiles() })
        menu.addItem(button("Show Vault in Finder", enabled: vault.isInstalled) { [vault] in vault.showVaultInFinder() })

        menu.addItem(.separator())
        menu.addItem(toggle("Close Documents When Mac Sleeps or Locks", on: vault.closeOnSleep) { [vault] in
            vault.closeOnSleep.toggle()
        })
        menu.addItem(toggle("Open at Login", on: vault.opensAtLogin) { [vault] in
            vault.setOpensAtLogin(!vault.opensAtLogin)
        })
        menu.addItem(.separator())
        menu.addItem(button("Quit IronVault", key: "q") { NSApp.terminate(nil) })
    }

    /// Keeps the countdowns moving while the menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveText() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func refreshLiveText() {
        statusItem?.title = vault.statusLine
        for entry in docItems {
            if let doc = vault.docs.first(where: { $0.id == entry.id }) {
                entry.item.title = docTitle(doc)
            } else {
                entry.item.title = "Closed"
                entry.item.isEnabled = false
            }
        }
    }

    private func docTitle(_ doc: VaultController.OpenDoc) -> String {
        "\(doc.name) · closes in \(vault.countdown(doc))"
    }

    // MARK: Item helpers

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func button(_ title: String, key: String = "", enabled: Bool = true,
                        _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = Action(run)
        item.isEnabled = enabled
        return item
    }

    private func toggle(_ title: String, on: Bool, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = button(title, run)
        item.state = on ? .on : .off
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }
}
