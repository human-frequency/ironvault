import AppKit
import IronVaultCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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

@main
struct IronVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vault = VaultController.shared

    var body: some Scene {
        MenuBarExtra {
            VaultMenu(vault: vault)
        } label: {
            Image(systemName: vault.unseenAlerts > 0 ? "lock.trianglebadge.exclamationmark.fill"
                              : vault.docs.isEmpty ? "lock.fill" : "lock.open.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
struct VaultMenu: View {
    @ObservedObject var vault: VaultController

    var body: some View {
        Text(vault.statusLine)
        Button(vault.unseenAlerts > 0
               ? "Dashboard… (\(vault.unseenAlerts) new alert\(vault.unseenAlerts == 1 ? "" : "s"))"
               : "Dashboard…") { DashboardWindow.show(vault) }
            .keyboardShortcut("d")
            .disabled(!vault.isInstalled)
        if vault.isInstalled && !vault.isVerified {
            Text("Run the self-test to finish setup.")
        }
        if let error = vault.lastError {
            Text(error)
        }
        Divider()

        if !vault.docs.isEmpty {
            ForEach(vault.docs) { doc in
                Menu("\(doc.name) · closes in \(vault.countdown(doc))") {
                    Button("Show") { vault.show(doc) }
                    Button("Keep Open 15 More Minutes") { vault.extend(doc) }
                    Button("Close and Wipe") { _ = vault.close(doc) }
                }
            }
            Button("Close All Documents") { vault.closeAll() }
                .keyboardShortcut("l")
            Divider()
        }

        Button("Open a Vault File…") { vault.chooseFileToOpen() }
            .disabled(!vault.isInstalled || vault.isBusy)
        Button("Add Files to Vault…") { vault.addFiles() }
            .disabled(!vault.isInstalled)
        Button("Show Vault in Finder") { vault.showVaultInFinder() }
            .disabled(!vault.isInstalled)

        Divider()
        Toggle("Close Documents When Mac Sleeps or Locks", isOn: $vault.closeOnSleep)
        Toggle("Open at Login", isOn: Binding(
            get: { vault.opensAtLogin },
            set: { vault.setOpensAtLogin($0) }
        ))
        Divider()
        Button("Quit IronVault") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
