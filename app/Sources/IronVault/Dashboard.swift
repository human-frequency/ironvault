import AppKit
import Combine
#if canImport(IronVaultCore)
import IronVaultCore   // separate module when built with Swift's package manager
#endif
import SwiftUI

/// Wording for each kind of event, shared by the Dashboard and notifications.
enum DashboardText {
    static func title(_ e: ActivityEvent) -> String {
        switch e.kind {
        case .request:
            switch e.outcome {
            case .approved: return "Opened \(e.displayFiles)"
            case .denied: return "Request to open \(e.displayFiles) was refused"
            default: return "Request to open \(e.displayFiles) failed"
            }
        case .read:
            return "\(e.displayFiles) was read outside IronVault"
        case .copyReader:
            return e.unusual ? "Open copy of \(e.displayFiles) was read by \(e.by ?? "a program")"
                             : "\(e.displayFiles) opened in \(e.by ?? "its app")"
        case .sealed:
            return "Sealed \(e.displayFiles)"
        }
    }

    static func detail(_ e: ActivityEvent) -> String {
        let who = e.by ?? "unknown"
        switch e.kind {
        case .request:
            let answer = e.outcome == .approved ? "Approved with Touch ID" : e.outcome == .denied ? "Touch ID was cancelled" : "Couldn't ask for Touch ID"
            return "\(answer) · asked by \(who)"
        case .read:
            let reader = e.by.map { "Read by \($0)" } ?? "The program had already closed it, so macOS couldn't say which one"
            return "\(reader). It only got encrypted data."
        case .copyReader:
            return e.unusual ? "Started by \(who). This program could read the document while it was open."
                             : "The decrypted copy was opened by this app."
        case .sealed:
            return "Added from \(who)"
        }
    }

    static func symbol(_ e: ActivityEvent) -> (name: String, color: Color) {
        switch e.kind {
        case .request:
            switch e.outcome {
            case .approved: return (e.unusual ? "exclamationmark.shield.fill" : "checkmark.shield.fill", e.unusual ? .orange : .green)
            case .denied: return ("xmark.shield.fill", .red)
            default: return ("exclamationmark.triangle.fill", .orange)
            }
        case .read: return ("eye.fill", .orange)
        case .copyReader: return (e.unusual ? "exclamationmark.triangle.fill" : "doc.text", e.unusual ? .red : .secondary)
        case .sealed: return ("lock.doc.fill", .secondary)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var vault: VaultController
    @State private var events: [ActivityEvent] = []
    @State private var onlyAlerts = false
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var lastWeek: [ActivityEvent] {
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        return events.filter { $0.time >= since }
    }
    private var shown: [ActivityEvent] { onlyAlerts ? events.filter(\.needsAttention) : events }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                statTile("Opened", lastWeek.filter { $0.kind == .request && $0.outcome == .approved }.count, .green)
                statTile("Refused", lastWeek.filter { $0.kind == .request && $0.outcome != .approved }.count, .red)
                statTile("Read outside IronVault", lastWeek.filter { $0.kind == .read }.count, .orange)
                statTile("Unusual readers", lastWeek.filter { $0.kind == .copyReader && $0.unusual }.count, .red)
            }
            Text("Last 7 days").font(.caption).foregroundStyle(.secondary)

            Picker("Show", selection: $onlyAlerts) {
                Text("Everything").tag(false)
                Text("Alerts only").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            if shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.largeTitle).foregroundStyle(.green)
                    Text(onlyAlerts ? "No alerts." : "Nothing has happened yet.")
                    Text("Every request to open a vault file, and every read IronVault can detect, appears here.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { event in row(event) }
                    .listStyle(.inset)
            }

            Text("IronVault records every request to open a vault file. Reads of sealed files outside IronVault are noticed within about 15 seconds, but macOS only names the program if it still has the file open. Those programs only ever get encrypted data.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { reload(); vault.markAlertsSeen() }
        .onReceive(refresh) { _ in reload() }
    }

    private func reload() { events = vault.events() }

    private func statTile(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(value > 0 ? color : Color.secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func row(_ e: ActivityEvent) -> some View {
        let symbol = DashboardText.symbol(e)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol.name).foregroundStyle(symbol.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(DashboardText.title(e)).fontWeight(e.needsAttention ? .semibold : .regular)
                Text(DashboardText.detail(e)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(e.time, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// A plain window, opened from the menu. Built by hand so it never appears on its own at login.
@MainActor
enum DashboardWindow {
    private static var window: NSWindow?

    static func show(_ vault: VaultController) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "IronVault Dashboard"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DashboardView(vault: vault))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        vault.markAlertsSeen()
    }
}
