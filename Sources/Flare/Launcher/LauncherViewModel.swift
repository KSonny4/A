import AppKit
import FlareCore
import SwiftUI

enum LauncherCommand: String, CaseIterable {
    case clipboardHistory, settings, welcome, quit

    var title: String {
        switch self {
        case .clipboardHistory: return "Clipboard History"
        case .settings: return "Flare Settings"
        case .welcome: return "Welcome to Flare"
        case .quit: return "Quit Flare"
        }
    }

    var symbol: String {
        switch self {
        case .clipboardHistory: return "doc.on.clipboard"
        case .settings: return "gearshape.fill"
        case .welcome: return "sparkles"
        case .quit: return "power"
        }
    }

    var tint: Color {
        switch self {
        case .clipboardHistory: return .orange
        case .settings: return .gray
        case .welcome: return .pink
        case .quit: return .red
        }
    }

    var keywords: [String] {
        switch self {
        case .clipboardHistory: return ["clipboard", "paste", "history", "copy"]
        case .settings: return ["preferences", "settings", "config"]
        case .welcome: return ["onboarding", "setup", "permissions"]
        case .quit: return ["exit", "close"]
        }
    }

    var entry: SearchEntry {
        SearchEntry(id: "cmd:" + rawValue, kind: .command, title: title, subtitle: "Flare", keywords: keywords)
    }

    static func from(id: String) -> LauncherCommand? {
        guard id.hasPrefix("cmd:") else { return nil }
        return LauncherCommand(rawValue: String(id.dropFirst(4)))
    }
}

struct LauncherItem: Identifiable {
    enum Payload {
        case entry(SearchEntry)
        case currency(CurrencyConversion, isPrimary: Bool)
        case currencyLoading(CurrencyQuery)
    }

    let id: String
    let payload: Payload
}

struct LauncherSection: Identifiable {
    let id: String
    let title: String
    let items: [LauncherItem]
}

@MainActor
final class LauncherViewModel: ObservableObject, PanelKeyHandler {
    @Published var query = "" {
        didSet { if query != oldValue { search() } }
    }
    @Published private(set) var sections: [LauncherSection] = []
    @Published var selectedID: String? = nil
    @Published var actionMenu = ActionMenuState()

    weak var panel: PanelController?
    var onCommand: ((LauncherCommand) -> Void)?

    let apps: AppIndex
    let downloads: DownloadsIndex
    let usage: UsageStore
    let currency: CurrencyService
    let preferences: Preferences

    private var items: [LauncherItem] = []
    private var generation = 0
    private let searchQueue = DispatchQueue(label: "flare.search", qos: .userInteractive)

    init(apps: AppIndex, downloads: DownloadsIndex, usage: UsageStore, currency: CurrencyService, preferences: Preferences) {
        self.apps = apps
        self.downloads = downloads
        self.usage = usage
        self.currency = currency
        self.preferences = preferences
        apps.onUpdate = { [weak self] in self?.search() }
        downloads.onUpdate = { [weak self] in
            guard let self, !self.query.isEmpty else { return }
            self.search()
        }
        search()
    }

    // MARK: - Panel

    func registerField(_ field: NSTextField) {
        panel?.searchField = field
    }

    func panelWillShow(resetState: Bool) {
        if resetState {
            actionMenu.close()
            if query.isEmpty { search() } else { query = "" }
        } else {
            search()
        }
    }

    func panelDidHide() {
        actionMenu.close()
    }

    // MARK: - Search

    func search() {
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let currencyItems = currencyItems(for: q)
        let appEntries = apps.snapshot() + LauncherCommand.allCases.map(\.entry)
        let usageSnapshot = usage.snapshot()

        if q.isEmpty {
            apply(emptyStateSections(appEntries: appEntries, usage: usageSnapshot))
            return
        }

        let downloads = self.downloads
        searchQueue.async {
            let topApps = SearchEngine.rank(appEntries, query: q, usage: usageSnapshot, limit: 12).map(\.entry)
            let topFiles = SearchEngine.rank(downloads.snapshot(), query: q, usage: usageSnapshot, limit: 40).map(\.entry)
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                var sections: [LauncherSection] = []
                if !currencyItems.isEmpty {
                    sections.append(LauncherSection(id: "currency", title: "Currency", items: currencyItems))
                }
                if !topApps.isEmpty {
                    sections.append(LauncherSection(id: "results", title: "Results",
                                                    items: topApps.map { LauncherItem(id: $0.id, payload: .entry($0)) }))
                }
                if !topFiles.isEmpty {
                    sections.append(LauncherSection(id: "files", title: "Files in Downloads",
                                                    items: topFiles.map { LauncherItem(id: $0.id, payload: .entry($0)) }))
                }
                self.apply(sections)
            }
        }
    }

    private func emptyStateSections(appEntries: [SearchEntry], usage: [String: UsageStat]) -> [LauncherSection] {
        let commandIDs = Set(LauncherCommand.allCases.map { "cmd:" + $0.rawValue })
        var suggestions = SearchEngine.suggestions(appEntries + downloads.snapshot(), usage: usage, limit: 6)
            .filter { !commandIDs.contains($0.id) }
        if suggestions.isEmpty {
            let defaults = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/System Settings.app"]
            suggestions = defaults.compactMap { path in appEntries.first { $0.path == path } }
        }
        var sections: [LauncherSection] = []
        if !suggestions.isEmpty {
            sections.append(LauncherSection(id: "suggestions", title: "Suggestions",
                                            items: suggestions.map { LauncherItem(id: $0.id, payload: .entry($0)) }))
        }
        sections.append(LauncherSection(id: "commands", title: "Commands",
                                        items: LauncherCommand.allCases.map { LauncherItem(id: "cmd:" + $0.rawValue, payload: .entry($0.entry)) }))
        return sections
    }

    private func currencyItems(for q: String) -> [LauncherItem] {
        guard q.count >= 2 else { return [] }
        let codes = currency.table?.codes
        guard let parsed = CurrencyQueryParser.parse(q, knownCodes: codes, defaultTargets: preferences.defaultCurrencyTargets) else {
            return []
        }
        if currency.needsRefresh {
            currency.refreshIfNeeded { [weak self] updated in
                guard updated else { return }
                Task { @MainActor in self?.search() }
            }
        }
        let conversions = currency.convert(parsed)
        if conversions.isEmpty {
            return currency.table == nil ? [LauncherItem(id: "currency-loading", payload: .currencyLoading(parsed))] : []
        }
        return conversions.enumerated().map { index, conversion in
            LauncherItem(id: "cur:" + conversion.id, payload: .currency(conversion, isPrimary: index == 0))
        }
    }

    private func apply(_ newSections: [LauncherSection]) {
        sections = newSections
        items = newSections.flatMap(\.items)
        selectedID = items.first?.id
    }

    var selectedItem: LauncherItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var hasResults: Bool { !items.isEmpty }

    // MARK: - Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        if actionMenu.isOpen {
            let result = actionMenu.handle(event)
            if let action = result.run { action.perform() }
            if result.handled { return true }
        }
        let mods = event.shortcutModifiers
        switch Int(event.keyCode) {
        case 126:
            move(-1)
        case 125:
            move(1)
        case 35 where mods == .control: // ⌃P
            move(-1)
        case 45 where mods == .control: // ⌃N
            move(1)
        case 36, 76:
            if mods.contains(.command) { runSecondary() } else { runPrimary() }
        case 53:
            if query.isEmpty { panel?.hide() } else { query = "" }
        case 40 where mods == .command: // ⌘K
            if actionMenu.isOpen { actionMenu.close() } else { actionMenu.open(actions(for: selectedItem)) }
        case 8 where mods == [.command, .shift]: // ⌘⇧C
            copyPath()
        case 43 where mods == .command: // ⌘,
            run(command: .settings)
        default:
            return false
        }
        return true
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        selectedID = items[next].id
    }

    // MARK: - Actions

    func select(_ item: LauncherItem) {
        selectedID = item.id
    }

    func activate(_ item: LauncherItem) {
        selectedID = item.id
        runPrimary()
    }

    func runPrimary() {
        guard let item = selectedItem else { return }
        switch item.payload {
        case .entry(let entry):
            open(entry)
        case .currency(let conversion, _):
            copy(CurrencyFormat.plain(conversion.result))
        case .currencyLoading:
            break
        }
    }

    func runSecondary() {
        guard let item = selectedItem else { return }
        switch item.payload {
        case .entry(let entry):
            if let command = LauncherCommand.from(id: entry.id) {
                run(command: command)
            } else if let path = entry.path {
                usage.record(entry.id)
                panel?.hide()
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .currency(let conversion, _):
            copy(CurrencyFormat.amount(conversion.result, code: conversion.to))
        case .currencyLoading:
            break
        }
    }

    private func open(_ entry: SearchEntry) {
        if let command = LauncherCommand.from(id: entry.id) {
            run(command: command)
            return
        }
        guard let path = entry.path else { return }
        usage.record(entry.id)
        panel?.hide()
        let url = URL(fileURLWithPath: path)
        if entry.kind == .application {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { NSLog("Flare: failed to open \(path): \(error)") }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func run(command: LauncherCommand) {
        usage.record("cmd:" + command.rawValue)
        panel?.hide()
        onCommand?(command)
    }

    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        panel?.hide()
        HUD.shared.show("Copied to Clipboard")
    }

    private func copyPath() {
        guard case .entry(let entry) = selectedItem?.payload, let path = entry.path else { return }
        copy(path)
    }

    private func copyFile(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        panel?.hide()
        HUD.shared.show("Copied File")
    }

    private func moveToTrash(_ entry: SearchEntry) {
        guard let path = entry.path else { return }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { [weak self] _, error in
            Task { @MainActor in
                if error == nil {
                    HUD.shared.show("Moved to Trash", symbol: "trash.fill")
                    self?.downloads.rebuild()
                }
            }
        }
        panel?.hide()
    }

    func actions(for item: LauncherItem?) -> [PanelAction] {
        guard let item else { return [] }
        switch item.payload {
        case .entry(let entry):
            if let command = LauncherCommand.from(id: entry.id) {
                return [PanelAction(title: "Run Command", symbol: "return", keys: ["↩"]) { [weak self] in self?.run(command: command) }]
            }
            guard let path = entry.path else { return [] }
            var actions = [
                PanelAction(title: entry.kind == .application ? "Open Application" : "Open", symbol: "arrow.up.forward.app", keys: ["↩"]) { [weak self] in self?.open(entry) },
                PanelAction(title: "Show in Finder", symbol: "folder", keys: ["⌘", "↩"]) { [weak self] in self?.runSecondary() },
                PanelAction(title: "Copy Path", symbol: "doc.on.doc", keys: ["⌘", "⇧", "C"]) { [weak self] in self?.copy(path) },
            ]
            if entry.kind != .application {
                actions.append(PanelAction(title: "Copy File", symbol: "doc.on.clipboard") { [weak self] in self?.copyFile(path) })
                actions.append(PanelAction(title: "Move to Trash", symbol: "trash", destructive: true) { [weak self] in self?.moveToTrash(entry) })
            }
            return actions
        case .currency(let conversion, _):
            return [
                PanelAction(title: "Copy Result", symbol: "doc.on.doc", keys: ["↩"]) { [weak self] in
                    self?.copy(CurrencyFormat.plain(conversion.result))
                },
                PanelAction(title: "Copy with Currency", symbol: "dollarsign.circle", keys: ["⌘", "↩"]) { [weak self] in
                    self?.copy(CurrencyFormat.amount(conversion.result, code: conversion.to))
                },
                PanelAction(title: "Refresh Exchange Rates", symbol: "arrow.clockwise") { [weak self] in
                    self?.currency.refreshIfNeeded(force: true) { _ in
                        Task { @MainActor in self?.search() }
                    }
                },
            ]
        case .currencyLoading:
            return []
        }
    }

    // MARK: - Presentation helpers

    var primaryActionTitle: String? {
        guard let item = selectedItem else { return nil }
        switch item.payload {
        case .entry(let entry):
            switch entry.kind {
            case .application: return "Open Application"
            case .file: return "Open File"
            case .folder: return "Open Folder"
            case .command: return "Run Command"
            }
        case .currency: return "Copy Result"
        case .currencyLoading: return nil
        }
    }

    var footerText: String {
        if case .currency? = selectedItem?.payload, let table = currency.table {
            let date = table.providerUpdatedAt ?? table.fetchedAt
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Exchange rates updated \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
        return "Flare"
    }
}
