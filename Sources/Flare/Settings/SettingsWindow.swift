import AppKit
import FlareCore
import SwiftUI

/// Apple-style preferences window with toolbar tabs.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let context: SettingsContext

    init(context: SettingsContext) {
        self.context = context
    }

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.canPropagateSelectedChildViewControllerTitle = true
            tabs.addTabViewItem(item("General", symbol: "gearshape", view: GeneralPane(context: context)))
            tabs.addTabViewItem(item("Clipboard", symbol: "doc.on.clipboard", view: ClipboardPane(context: context)))
            tabs.addTabViewItem(item("Currency", symbol: "dollarsign.circle", view: CurrencyPane(context: context)))
            tabs.addTabViewItem(item("About", symbol: "info.circle", view: AboutPane()))

            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .preference
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func item<V: View>(_ title: String, symbol: String, view: V) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view.frame(width: 520).fixedSize())
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// Everything the settings panes need.
@MainActor
final class SettingsContext: ObservableObject {
    let preferences: Preferences
    let store: ClipboardStore
    let storeQueue: DispatchQueue
    let currency: CurrencyService
    var onHotKeysChanged: () -> Void = {}
    var onShowWelcome: () -> Void = {}
    var onClearHistory: () -> Void = {}

    @Published var clipCount = 0
    @Published var diskUsage: Int64 = 0

    init(preferences: Preferences, store: ClipboardStore, storeQueue: DispatchQueue, currency: CurrencyService) {
        self.preferences = preferences
        self.store = store
        self.storeQueue = storeQueue
        self.currency = currency
    }

    func refreshStats() {
        let store = self.store
        storeQueue.async {
            let count = (try? store.count()) ?? 0
            let usage = store.diskUsage()
            Task { @MainActor [weak self] in
                self?.clipCount = count
                self?.diskUsage = usage
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .frame(width: 150, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var context: SettingsContext
    @ObservedObject var preferences: Preferences

    init(context: SettingsContext) {
        self.context = context
        preferences = context.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow(label: "Startup:") {
                Toggle("Launch Flare at login", isOn: $preferences.launchAtLogin)
            }
            SettingsRow(label: "Open Flare:") {
                HotKeyRecorder(combo: $preferences.launcherHotKey)
            }
            SettingsRow(label: "Clipboard History:") {
                HotKeyRecorder(combo: $preferences.clipboardHotKey)
            }
            if preferences.launcherHotKey == .commandSpace && PermissionsService.spotlightOwnsCommandSpace() {
                SettingsRow(label: "") {
                    Text("⚠️ Spotlight still uses ⌘ Space. Disable it in Keyboard Shortcuts → Spotlight.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            SettingsRow(label: "Setup:") {
                Button("Show Welcome Guide…") { context.onShowWelcome() }
            }
        }
        .padding(24)
        .onChange(of: preferences.launcherHotKey) { _ in context.onHotKeysChanged() }
        .onChange(of: preferences.clipboardHotKey) { _ in context.onHotKeysChanged() }
    }
}

private struct ClipboardPane: View {
    @ObservedObject var context: SettingsContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow(label: "History:") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(context.clipCount.formatted()) entries · \(ByteCountFormatter.string(fromByteCount: context.diskUsage, countStyle: .file))")
                    Text("Unlimited — every copy is kept forever, at any size.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            SettingsRow(label: "Paste:") {
                VStack(alignment: .leading, spacing: 4) {
                    if PermissionsService.isAccessibilityTrusted {
                        Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow Accessibility Access…") { PermissionsService.requestAccessibility() }
                        Text("Needed to paste directly into the app you were using.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SettingsRow(label: "Privacy:") {
                Text("Items marked as concealed by password managers are never recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            SettingsRow(label: "Data:") {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([context.store.directory])
                    }
                    Button("Clear History…") { context.onClearHistory() }
                }
            }
        }
        .padding(24)
        .onAppear { context.refreshStats() }
    }
}

private struct CurrencyPane: View {
    @ObservedObject var context: SettingsContext
    @ObservedObject var preferences: Preferences
    @State private var refreshing = false

    init(context: SettingsContext) {
        self.context = context
        preferences = context.preferences
    }

    private var codes: [String] {
        let known = context.currency.table?.codes ?? Set(Locale.commonISOCurrencyCodes)
        return known.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow(label: "Home currency:") {
                Picker("", selection: $preferences.homeCurrency) {
                    ForEach(codes, id: \.self) { code in
                        Text("\(code) — \(CurrencyFormat.name(code))").tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
            }
            SettingsRow(label: "Exchange rates:") {
                VStack(alignment: .leading, spacing: 6) {
                    if let table = context.currency.table {
                        Text("Updated \((table.providerUpdatedAt ?? table.fetchedAt).formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Not downloaded yet")
                    }
                    Text("Source: open.er-api.com · refreshed automatically every 12 hours")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(refreshing ? "Refreshing…" : "Refresh Now") {
                        refreshing = true
                        context.currency.refreshIfNeeded(force: true) { _ in
                            Task { @MainActor in
                                refreshing = false
                                context.objectWillChange.send()
                            }
                        }
                    }
                    .disabled(refreshing)
                }
            }
            SettingsRow(label: "Try:") {
                Text("“100 usd to eur”, “€50 in czk”, “20 gbp”")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Flare")
                .font(.system(size: 22, weight: .bold))
            Text("Version \(AppInfo.version)")
                .foregroundStyle(.secondary)
            Text("Your shortcut to everything.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}

/// Click, then press a new shortcut. Esc cancels.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 6) {
                if recording {
                    Text("Press shortcut…")
                        .foregroundStyle(.secondary)
                } else {
                    KeycapRow(keys: combo.keycaps, size: 12)
                }
            }
            .frame(minWidth: 150, minHeight: 26)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(recording ? Theme.accent : Theme.border, lineWidth: recording ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 {
            stop()
        } else if let newCombo = KeyCombo(event: event) {
            combo = newCombo
            stop()
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
